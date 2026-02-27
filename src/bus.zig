const std = @import("std");
const builtin = @import("builtin");

/// 1MB memory bus for the 8086.
///
/// The 8086 has a 20-bit address space (1,048,576 bytes). Segment:offset
/// addressing is resolved here: physical = segment * 16 + offset.
///
/// On native targets the memory is heap-allocated via page_allocator.
/// On wasm32 it lives as a static array in linear memory.
pub const Bus = struct {
    mem: *[1048576]u8,

    /// Output buffer for INT 21h text output (readable from JS via pointer).
    output_buf: *[4096]u8,
    output_len: u32 = 0,

    /// Set by INT 21h AH=4Ch to signal program exit.
    halted: bool = false,

    const is_wasm = builtin.cpu.arch == .wasm32;

    // Static storage for WASM (lives in linear memory, visible to JS).
    var static_mem: [1048576]u8 = [_]u8{0} ** 1048576;
    var static_output: [4096]u8 = [_]u8{0} ** 4096;

    pub fn init() Bus {
        if (is_wasm) {
            return .{
                .mem = &static_mem,
                .output_buf = &static_output,
            };
        } else {
            const mem = std.heap.page_allocator.create([1048576]u8) catch @panic("out of memory");
            @memset(mem, 0);
            const out = std.heap.page_allocator.create([4096]u8) catch @panic("out of memory");
            @memset(out, 0);
            return .{ .mem = mem, .output_buf = out };
        }
    }

    pub fn deinit(self: *Bus) void {
        if (!is_wasm) {
            std.heap.page_allocator.destroy(self.mem);
            std.heap.page_allocator.destroy(self.output_buf);
        }
    }

    pub fn reset(self: *Bus) void {
        @memset(self.mem, 0);
        @memset(self.output_buf, 0);
        self.output_len = 0;
        self.halted = false;
    }

    /// Append a character to the output buffer.
    pub fn appendOutput(self: *Bus, ch: u8) void {
        if (self.output_len < self.output_buf.len) {
            self.output_buf[self.output_len] = ch;
            self.output_len += 1;
        }
    }

    /// Compute 20-bit physical address from segment:offset.
    /// Wraps at 1MB boundary (the 8086 has no A20 gate).
    pub fn physicalAddress(segment: u16, offset: u16) u20 {
        const addr: u21 = @as(u21, segment) * 16 + @as(u21, offset);
        return @truncate(addr);
    }

    /// Read a byte from segment:offset.
    pub fn read8(self: *const Bus, segment: u16, offset: u16) u8 {
        return self.mem[physicalAddress(segment, offset)];
    }

    /// Read a 16-bit word from segment:offset (little-endian).
    pub fn read16(self: *const Bus, segment: u16, offset: u16) u16 {
        const lo = self.read8(segment, offset);
        const hi = self.read8(segment, offset +% 1);
        return @as(u16, hi) << 8 | lo;
    }

    /// Write a byte to segment:offset.
    pub fn write8(self: *Bus, segment: u16, offset: u16, val: u8) void {
        self.mem[physicalAddress(segment, offset)] = val;
    }

    /// Write a 16-bit word to segment:offset (little-endian).
    pub fn write16(self: *Bus, segment: u16, offset: u16, val: u16) void {
        self.write8(segment, offset, @truncate(val));
        self.write8(segment, offset +% 1, @truncate(val >> 8));
    }

    /// Read a byte by physical address.
    pub fn readPhys8(self: *const Bus, addr: u20) u8 {
        return self.mem[addr];
    }

    /// Write a byte by physical address.
    pub fn writePhys8(self: *Bus, addr: u20, val: u8) void {
        self.mem[addr] = val;
    }

    /// Read a 16-bit word by physical address (little-endian).
    pub fn readPhys16(self: *const Bus, addr: u20) u16 {
        const lo = self.mem[addr];
        const hi = self.mem[addr +% 1];
        return @as(u16, hi) << 8 | lo;
    }

    /// Write a 16-bit word by physical address (little-endian).
    pub fn writePhys16(self: *Bus, addr: u20, val: u16) void {
        self.mem[addr] = @truncate(val);
        self.mem[addr +% 1] = @truncate(val >> 8);
    }

    // --- I/O ports (stubs) ---

    pub fn inPort8(_: *const Bus, _: u16) u8 {
        return 0xFF; // open bus
    }

    pub fn outPort8(_: *Bus, _: u16, _: u8) void {
        // no-op
    }
};

// --- Tests ---

test "physical address calculation" {
    // Simple case: segment 0x1000, offset 0x0100 = 0x10100
    try std.testing.expectEqual(@as(u20, 0x10100), Bus.physicalAddress(0x1000, 0x0100));

    // Segment 0xFFFF, offset 0x0010 = 0xFFFF0 + 0x10 = 0x100000 -> wraps to 0x00000
    try std.testing.expectEqual(@as(u20, 0x00000), Bus.physicalAddress(0xFFFF, 0x0010));
}

test "read/write byte" {
    var bus = Bus.init();
    defer bus.deinit();

    bus.write8(0x0000, 0x0100, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), bus.read8(0x0000, 0x0100));
}

test "read/write word little-endian" {
    var bus = Bus.init();
    defer bus.deinit();

    bus.write16(0x0000, 0x0200, 0xBEEF);
    try std.testing.expectEqual(@as(u16, 0xBEEF), bus.read16(0x0000, 0x0200));

    // Verify byte order in memory
    try std.testing.expectEqual(@as(u8, 0xEF), bus.read8(0x0000, 0x0200)); // low byte first
    try std.testing.expectEqual(@as(u8, 0xBE), bus.read8(0x0000, 0x0201)); // high byte second
}

test "segment:offset aliasing" {
    var bus = Bus.init();
    defer bus.deinit();

    // 0x0010:0x0000 and 0x0000:0x0100 both map to physical 0x00100
    bus.write8(0x0010, 0x0000, 0xAA);
    try std.testing.expectEqual(@as(u8, 0xAA), bus.read8(0x0000, 0x0100));
}
