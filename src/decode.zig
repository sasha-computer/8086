const std = @import("std");
const Cpu = @import("cpu.zig").Cpu;
const Bus = @import("bus.zig").Bus;

/// Decoded ModR/M byte fields.
pub const ModRM = struct {
    mod: u2,
    reg: u3,
    rm: u3,
};

/// Result of decoding a ModR/M operand's effective address.
pub const EffectiveAddress = union(enum) {
    /// Memory operand at a physical address, with the segment used.
    memory: struct {
        segment: u16,
        offset: u16,
    },
    /// Register operand (mod == 3). The register index for getReg8/getReg16.
    register: u3,
};

/// Instruction decoder.
///
/// Fetches bytes from CS:IP, advances IP, and decodes ModR/M + displacement.
/// This is stateless -- it takes a CPU and Bus reference and modifies IP as it
/// consumes bytes.
pub const Decoder = struct {
    /// Fetch a byte from CS:IP and advance IP.
    pub fn fetchByte(cpu: *Cpu, bus: *const Bus) u8 {
        const val = bus.read8(cpu.cs, cpu.ip);
        cpu.ip +%= 1;
        return val;
    }

    /// Fetch a 16-bit word from CS:IP (little-endian) and advance IP by 2.
    pub fn fetchWord(cpu: *Cpu, bus: *const Bus) u16 {
        const lo = fetchByte(cpu, bus);
        const hi = fetchByte(cpu, bus);
        return @as(u16, hi) << 8 | lo;
    }

    /// Decode a ModR/M byte into its three fields.
    pub fn decodeModRM(byte: u8) ModRM {
        return .{
            .mod = @truncate(byte >> 6),
            .reg = @truncate((byte >> 3) & 0x07),
            .rm = @truncate(byte & 0x07),
        };
    }

    /// Given a decoded ModR/M, compute the effective address.
    ///
    /// For mod != 3, calculates the memory address from the R/M field,
    /// fetching any displacement bytes from CS:IP.
    ///
    /// `seg_override` allows a segment override prefix to replace the
    /// default segment. Pass `null` for the default.
    pub fn resolveModRM(
        cpu: *Cpu,
        bus: *const Bus,
        modrm: ModRM,
        seg_override: ?u16,
    ) EffectiveAddress {
        if (modrm.mod == 3) {
            return .{ .register = modrm.rm };
        }

        // Calculate base offset from R/M field
        var offset: u16 = switch (modrm.rm) {
            0 => cpu.bx.word +% cpu.si, // [BX+SI]
            1 => cpu.bx.word +% cpu.di, // [BX+DI]
            2 => cpu.bp +% cpu.si, // [BP+SI]
            3 => cpu.bp +% cpu.di, // [BP+DI]
            4 => cpu.si, // [SI]
            5 => cpu.di, // [DI]
            6 => if (modrm.mod == 0) 0 else cpu.bp, // [disp16] or [BP+disp]
            7 => cpu.bx.word, // [BX]
        };

        // Default segment: SS for BP-based addressing, DS otherwise
        const default_seg = if (modrm.rm == 2 or modrm.rm == 3 or
            (modrm.rm == 6 and modrm.mod != 0))
            cpu.ss
        else
            cpu.ds;

        // Fetch displacement
        switch (modrm.mod) {
            0 => {
                if (modrm.rm == 6) {
                    // Special case: direct address [disp16]
                    offset = fetchWord(cpu, bus);
                }
                // mod=0 with rm!=6: no displacement
            },
            1 => {
                // 8-bit signed displacement
                const disp: i8 = @bitCast(fetchByte(cpu, bus));
                offset +%= @bitCast(@as(i16, disp));
            },
            2 => {
                // 16-bit displacement
                const disp = fetchWord(cpu, bus);
                offset +%= disp;
            },
            3 => unreachable, // handled above
        }

        return .{
            .memory = .{
                .segment = seg_override orelse default_seg,
                .offset = offset,
            },
        };
    }
};

// --- Tests ---

test "ModR/M decode" {
    // 0xC0 = mod=3, reg=0, rm=0 (AL, AL in 8-bit context)
    const modrm = Decoder.decodeModRM(0xC0);
    try std.testing.expectEqual(@as(u2, 3), modrm.mod);
    try std.testing.expectEqual(@as(u3, 0), modrm.reg);
    try std.testing.expectEqual(@as(u3, 0), modrm.rm);
}

test "ModR/M decode 0xDB" {
    // 0xDB = 11_011_011 -> mod=3, reg=3, rm=3
    const modrm = Decoder.decodeModRM(0xDB);
    try std.testing.expectEqual(@as(u2, 3), modrm.mod);
    try std.testing.expectEqual(@as(u3, 3), modrm.reg);
    try std.testing.expectEqual(@as(u3, 3), modrm.rm);
}

test "fetch byte advances IP" {
    var cpu = Cpu.init();
    var bus = Bus.init();
    defer bus.deinit();

    bus.write8(0, 0, 0x42);
    bus.write8(0, 1, 0x43);

    const b1 = Decoder.fetchByte(&cpu, &bus);
    try std.testing.expectEqual(@as(u8, 0x42), b1);
    try std.testing.expectEqual(@as(u16, 1), cpu.ip);

    const b2 = Decoder.fetchByte(&cpu, &bus);
    try std.testing.expectEqual(@as(u8, 0x43), b2);
    try std.testing.expectEqual(@as(u16, 2), cpu.ip);
}

test "fetch word advances IP by 2" {
    var cpu = Cpu.init();
    var bus = Bus.init();
    defer bus.deinit();

    bus.write16(0, 0, 0xBEEF);
    const w = Decoder.fetchWord(&cpu, &bus);
    try std.testing.expectEqual(@as(u16, 0xBEEF), w);
    try std.testing.expectEqual(@as(u16, 2), cpu.ip);
}

test "resolveModRM mod=3 register" {
    var cpu = Cpu.init();
    var bus = Bus.init();
    defer bus.deinit();

    const modrm = Decoder.decodeModRM(0xC3); // mod=3, reg=0, rm=3
    const ea = Decoder.resolveModRM(&cpu, &bus, modrm, null);
    try std.testing.expectEqual(@as(u3, 3), ea.register);
}

test "resolveModRM mod=0 rm=6 direct address" {
    var cpu = Cpu.init();
    var bus = Bus.init();
    defer bus.deinit();

    cpu.ds = 0x0100;
    // ModR/M byte: mod=0, reg=0, rm=6 = 0x06
    // Followed by 16-bit displacement 0x1234
    bus.write8(0, 0, 0x34);
    bus.write8(0, 1, 0x12);

    const modrm = Decoder.decodeModRM(0x06);
    const ea = Decoder.resolveModRM(&cpu, &bus, modrm, null);
    try std.testing.expectEqual(@as(u16, 0x0100), ea.memory.segment);
    try std.testing.expectEqual(@as(u16, 0x1234), ea.memory.offset);
}

test "resolveModRM mod=1 signed displacement" {
    var cpu = Cpu.init();
    var bus = Bus.init();
    defer bus.deinit();

    cpu.bx.word = 0x0100;
    // ModR/M: mod=1, reg=0, rm=7 (BX + disp8) = 0x47
    // disp8 = -2 (0xFE)
    bus.write8(0, 0, 0xFE);

    const modrm = Decoder.decodeModRM(0x47);
    const ea = Decoder.resolveModRM(&cpu, &bus, modrm, null);
    try std.testing.expectEqual(@as(u16, 0x00FE), ea.memory.offset); // 0x100 + (-2)
}
