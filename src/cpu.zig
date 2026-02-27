const std = @import("std");

/// 8086 CPU state: general-purpose registers, segment registers, IP, and FLAGS.
///
/// General-purpose registers use packed unions so AX/AH/AL (etc.) share storage
/// naturally, matching the real hardware layout.
pub const Cpu = struct {
    /// General-purpose register with hi/lo byte access.
    /// The 8086 is little-endian: the low byte is at the lower address.
    pub const GpReg = packed union {
        word: u16,
        parts: packed struct(u16) {
            lo: u8,
            hi: u8,
        },
    };

    // General-purpose registers
    ax: GpReg = .{ .word = 0 },
    bx: GpReg = .{ .word = 0 },
    cx: GpReg = .{ .word = 0 },
    dx: GpReg = .{ .word = 0 },

    // Index / pointer registers
    si: u16 = 0,
    di: u16 = 0,
    bp: u16 = 0,
    sp: u16 = 0,

    // Segment registers
    cs: u16 = 0,
    ds: u16 = 0,
    ss: u16 = 0,
    es: u16 = 0,

    // Instruction pointer
    ip: u16 = 0,

    // FLAGS -- stored as individual bools, packed on demand.
    flags: Flags = .{},

    pub const Flags = struct {
        carry: bool = false, // CF - bit 0
        parity: bool = false, // PF - bit 2
        aux_carry: bool = false, // AF - bit 4
        zero: bool = false, // ZF - bit 6
        sign: bool = false, // SF - bit 7
        trap: bool = false, // TF - bit 8
        interrupt: bool = false, // IF - bit 9
        direction: bool = false, // DF - bit 10
        overflow: bool = false, // OF - bit 11

        /// Pack individual flags into the 16-bit FLAGS register value.
        /// Bits 1, 3, 5 are always 0; bit 12-15 are always 1 on 8086.
        pub fn pack(self: Flags) u16 {
            var val: u16 = 0xF002; // bits 12-15 = 1, bit 1 = 1 (fixed on 8086)
            if (self.carry) val |= (1 << 0);
            if (self.parity) val |= (1 << 2);
            if (self.aux_carry) val |= (1 << 4);
            if (self.zero) val |= (1 << 6);
            if (self.sign) val |= (1 << 7);
            if (self.trap) val |= (1 << 8);
            if (self.interrupt) val |= (1 << 9);
            if (self.direction) val |= (1 << 10);
            if (self.overflow) val |= (1 << 11);
            return val;
        }

        /// Unpack a 16-bit FLAGS register value into individual flags.
        pub fn unpack(val: u16) Flags {
            return .{
                .carry = (val & (1 << 0)) != 0,
                .parity = (val & (1 << 2)) != 0,
                .aux_carry = (val & (1 << 4)) != 0,
                .zero = (val & (1 << 6)) != 0,
                .sign = (val & (1 << 7)) != 0,
                .trap = (val & (1 << 8)) != 0,
                .interrupt = (val & (1 << 9)) != 0,
                .direction = (val & (1 << 10)) != 0,
                .overflow = (val & (1 << 11)) != 0,
            };
        }
    };

    pub fn init() Cpu {
        return .{};
    }

    // --- Register access by 3-bit encoding (as used in ModR/M) ---

    /// Read a 16-bit register by its 3-bit encoding.
    /// 0=AX, 1=CX, 2=DX, 3=BX, 4=SP, 5=BP, 6=SI, 7=DI
    pub fn getReg16(self: *const Cpu, reg: u3) u16 {
        return switch (reg) {
            0 => self.ax.word,
            1 => self.cx.word,
            2 => self.dx.word,
            3 => self.bx.word,
            4 => self.sp,
            5 => self.bp,
            6 => self.si,
            7 => self.di,
        };
    }

    /// Write a 16-bit register by its 3-bit encoding.
    pub fn setReg16(self: *Cpu, reg: u3, val: u16) void {
        switch (reg) {
            0 => self.ax.word = val,
            1 => self.cx.word = val,
            2 => self.dx.word = val,
            3 => self.bx.word = val,
            4 => self.sp = val,
            5 => self.bp = val,
            6 => self.si = val,
            7 => self.di = val,
        }
    }

    /// Read an 8-bit register by its 3-bit encoding.
    /// 0=AL, 1=CL, 2=DL, 3=BL, 4=AH, 5=CH, 6=DH, 7=BH
    pub fn getReg8(self: *const Cpu, reg: u3) u8 {
        return switch (reg) {
            0 => self.ax.parts.lo,
            1 => self.cx.parts.lo,
            2 => self.dx.parts.lo,
            3 => self.bx.parts.lo,
            4 => self.ax.parts.hi,
            5 => self.cx.parts.hi,
            6 => self.dx.parts.hi,
            7 => self.bx.parts.hi,
        };
    }

    /// Write an 8-bit register by its 3-bit encoding.
    pub fn setReg8(self: *Cpu, reg: u3, val: u8) void {
        switch (reg) {
            0 => self.ax.parts.lo = val,
            1 => self.cx.parts.lo = val,
            2 => self.dx.parts.lo = val,
            3 => self.bx.parts.lo = val,
            4 => self.ax.parts.hi = val,
            5 => self.cx.parts.hi = val,
            6 => self.dx.parts.hi = val,
            7 => self.bx.parts.hi = val,
        }
    }

    /// Read a segment register by its 2-bit encoding.
    /// 0=ES, 1=CS, 2=SS, 3=DS
    pub fn getSegReg(self: *const Cpu, reg: u2) u16 {
        return switch (reg) {
            0 => self.es,
            1 => self.cs,
            2 => self.ss,
            3 => self.ds,
        };
    }

    /// Write a segment register by its 2-bit encoding.
    pub fn setSegReg(self: *Cpu, reg: u2, val: u16) void {
        switch (reg) {
            0 => self.es = val,
            1 => self.cs = val,
            2 => self.ss = val,
            3 => self.ds = val,
        }
    }
};

// --- Tests ---

test "GpReg hi/lo byte access" {
    var reg = Cpu.GpReg{ .word = 0x1234 };
    try std.testing.expectEqual(@as(u8, 0x34), reg.parts.lo);
    try std.testing.expectEqual(@as(u8, 0x12), reg.parts.hi);

    reg.parts.hi = 0xAB;
    try std.testing.expectEqual(@as(u16, 0xAB34), reg.word);

    reg.parts.lo = 0xCD;
    try std.testing.expectEqual(@as(u16, 0xABCD), reg.word);
}

test "FLAGS pack/unpack roundtrip" {
    const flags = Cpu.Flags{
        .carry = true,
        .zero = true,
        .sign = true,
        .overflow = true,
    };
    const raw = flags.pack();
    const unpacked = Cpu.Flags.unpack(raw);
    try std.testing.expectEqual(flags.carry, unpacked.carry);
    try std.testing.expectEqual(flags.zero, unpacked.zero);
    try std.testing.expectEqual(flags.sign, unpacked.sign);
    try std.testing.expectEqual(flags.overflow, unpacked.overflow);
    try std.testing.expectEqual(flags.parity, unpacked.parity);
    try std.testing.expectEqual(flags.aux_carry, unpacked.aux_carry);
}

test "FLAGS pack has fixed bits set" {
    const flags = Cpu.Flags{};
    const raw = flags.pack();
    // Bit 1 is always 1 on 8086
    try std.testing.expect((raw & 0x02) != 0);
    // Bits 12-15 are always 1 on 8086
    try std.testing.expect((raw & 0xF000) == 0xF000);
}

test "register access by encoding" {
    var cpu = Cpu.init();
    cpu.setReg16(0, 0x1234); // AX
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.getReg16(0));
    try std.testing.expectEqual(@as(u8, 0x34), cpu.getReg8(0)); // AL
    try std.testing.expectEqual(@as(u8, 0x12), cpu.getReg8(4)); // AH

    cpu.setReg8(5, 0xFF); // CH
    try std.testing.expectEqual(@as(u8, 0xFF), cpu.getReg8(5));
    try std.testing.expectEqual(@as(u16, 0xFF00), cpu.cx.word);
}

test "segment register access" {
    var cpu = Cpu.init();
    cpu.setSegReg(1, 0x0800); // CS
    try std.testing.expectEqual(@as(u16, 0x0800), cpu.cs);
    try std.testing.expectEqual(@as(u16, 0x0800), cpu.getSegReg(1));
}
