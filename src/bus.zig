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

    /// When true, INT 10h/16h/21h/20h are intercepted by the emulator
    /// instead of going through the IVT. Used by WASM and the native debugger.
    intercept_bios: bool = Bus.is_wasm,

    // --- Video state ---

    /// Current video mode (0x03 = 80x25 text, 0x13 = 320x200 graphics).
    video_mode: u8 = 0x03,

    /// Cursor position (row 0-24, col 0-79 in text mode).
    cursor_row: u8 = 0,
    cursor_col: u8 = 0,

    /// Active display page (most programs use page 0).
    active_page: u8 = 0,

    // --- Keyboard buffer ---

    /// Circular keyboard buffer: each entry is (scan_code, ascii).
    /// 16 entries, matching the real BIOS keyboard buffer size.
    key_buf: [16]KeyEntry = [_]KeyEntry{.{}} ** 16,
    key_head: u4 = 0,
    key_tail: u4 = 0,

    /// Whether we are waiting for a key (INT 16h AH=00h blocks).
    waiting_for_key: bool = false,

    pub const KeyEntry = struct {
        scancode: u8 = 0,
        ascii: u8 = 0,
    };
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
        self.video_mode = 0x03;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.active_page = 0;
        self.key_buf = [_]KeyEntry{.{}} ** 16;
        self.key_head = 0;
        self.key_tail = 0;
        self.waiting_for_key = false;
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

    // --- Keyboard buffer operations ---

    /// Push a key into the buffer. Returns false if buffer is full.
    pub fn pushKey(self: *Bus, scancode: u8, ascii: u8) bool {
        const next: u4 = self.key_tail +% 1;
        if (next == self.key_head) return false; // full
        self.key_buf[self.key_tail] = .{ .scancode = scancode, .ascii = ascii };
        self.key_tail = next;
        return true;
    }

    /// Peek at the next key without consuming it. Returns null if empty.
    pub fn peekKey(self: *const Bus) ?KeyEntry {
        if (self.key_head == self.key_tail) return null;
        return self.key_buf[self.key_head];
    }

    /// Consume and return the next key. Returns null if empty.
    pub fn popKey(self: *Bus) ?KeyEntry {
        if (self.key_head == self.key_tail) return null;
        const entry = self.key_buf[self.key_head];
        self.key_head +%= 1;
        return entry;
    }

    /// Check if the keyboard buffer has keys.
    pub fn hasKey(self: *const Bus) bool {
        return self.key_head != self.key_tail;
    }

    // --- Text-mode video helpers ---

    /// Physical address of the text-mode framebuffer (B800:0000 = 0xB8000).
    pub const TEXT_VRAM_BASE: u20 = 0xB8000;

    /// Write a character + attribute to text VRAM at (row, col).
    pub fn writeTextCell(self: *Bus, row: u8, col: u8, char: u8, attr: u8) void {
        const offset: u20 = (@as(u20, row) * 80 + @as(u20, col)) * 2;
        const addr = TEXT_VRAM_BASE + offset;
        self.mem[addr] = char;
        self.mem[addr + 1] = attr;
    }

    /// Advance cursor by one position, handling line wrap and scrolling.
    pub fn advanceCursor(self: *Bus) void {
        self.cursor_col += 1;
        if (self.cursor_col >= 80) {
            self.cursor_col = 0;
            self.cursor_row += 1;
        }
        if (self.cursor_row >= 25) {
            self.scrollUp();
            self.cursor_row = 24;
        }
    }

    /// Scroll the text-mode framebuffer up by one line.
    pub fn scrollUp(self: *Bus) void {
        // Copy rows 1-24 to rows 0-23
        const src_start = TEXT_VRAM_BASE + 160; // row 1
        const dst_start = TEXT_VRAM_BASE; // row 0
        const copy_len: u20 = 24 * 160;
        var i: u20 = 0;
        while (i < copy_len) : (i += 1) {
            self.mem[dst_start + i] = self.mem[src_start + i];
        }
        // Clear last row (row 24)
        const last_row = TEXT_VRAM_BASE + 24 * 160;
        var j: u20 = 0;
        while (j < 160) : (j += 2) {
            self.mem[last_row + j] = 0x20; // space
            self.mem[last_row + j + 1] = 0x07; // default attribute (white on black)
        }
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

test "keyboard buffer push/pop" {
    var bus = Bus.init();
    defer bus.deinit();

    // Empty buffer
    try std.testing.expect(!bus.hasKey());
    try std.testing.expect(bus.popKey() == null);
    try std.testing.expect(bus.peekKey() == null);

    // Push a key
    try std.testing.expect(bus.pushKey(0x48, 0x00)); // Up arrow
    try std.testing.expect(bus.hasKey());

    // Peek doesn't consume
    const peeked = bus.peekKey().?;
    try std.testing.expectEqual(@as(u8, 0x48), peeked.scancode);
    try std.testing.expectEqual(@as(u8, 0x00), peeked.ascii);
    try std.testing.expect(bus.hasKey());

    // Pop consumes
    const popped = bus.popKey().?;
    try std.testing.expectEqual(@as(u8, 0x48), popped.scancode);
    try std.testing.expect(!bus.hasKey());
    try std.testing.expect(bus.popKey() == null);
}

test "keyboard buffer wraps and rejects when full" {
    var bus = Bus.init();
    defer bus.deinit();

    // Fill buffer (15 entries, since circular buffer of 16 wastes one slot)
    var i: u8 = 0;
    while (i < 15) : (i += 1) {
        try std.testing.expect(bus.pushKey(i, i));
    }
    // 16th push should fail (full)
    try std.testing.expect(!bus.pushKey(0xFF, 0xFF));

    // Pop all and verify order
    i = 0;
    while (i < 15) : (i += 1) {
        const key = bus.popKey().?;
        try std.testing.expectEqual(i, key.scancode);
    }
    try std.testing.expect(bus.popKey() == null);
}

test "writeTextCell writes char+attr to VRAM" {
    var bus = Bus.init();
    defer bus.deinit();

    bus.writeTextCell(0, 0, 'A', 0x1F); // row 0, col 0
    try std.testing.expectEqual(@as(u8, 'A'), bus.mem[Bus.TEXT_VRAM_BASE]);
    try std.testing.expectEqual(@as(u8, 0x1F), bus.mem[Bus.TEXT_VRAM_BASE + 1]);

    // Row 1, col 5 = offset (1*80+5)*2 = 170
    bus.writeTextCell(1, 5, 'B', 0x07);
    try std.testing.expectEqual(@as(u8, 'B'), bus.mem[Bus.TEXT_VRAM_BASE + 170]);
    try std.testing.expectEqual(@as(u8, 0x07), bus.mem[Bus.TEXT_VRAM_BASE + 171]);
}

test "advanceCursor wraps at column 80" {
    var bus = Bus.init();
    defer bus.deinit();

    bus.cursor_row = 0;
    bus.cursor_col = 79;
    bus.advanceCursor();
    try std.testing.expectEqual(@as(u8, 0), bus.cursor_col);
    try std.testing.expectEqual(@as(u8, 1), bus.cursor_row);
}

test "advanceCursor scrolls at row 25" {
    var bus = Bus.init();
    defer bus.deinit();

    // Put recognizable data in row 1
    bus.writeTextCell(1, 0, 'X', 0x4E);
    bus.cursor_row = 24;
    bus.cursor_col = 79;
    bus.advanceCursor();

    // Should have scrolled: cursor stays at row 24, col 0
    try std.testing.expectEqual(@as(u8, 0), bus.cursor_col);
    try std.testing.expectEqual(@as(u8, 24), bus.cursor_row);

    // Row 1 data should now be at row 0 (scrolled up)
    try std.testing.expectEqual(@as(u8, 'X'), bus.mem[Bus.TEXT_VRAM_BASE]);
    try std.testing.expectEqual(@as(u8, 0x4E), bus.mem[Bus.TEXT_VRAM_BASE + 1]);
}

test "scrollUp moves rows up and clears last row" {
    var bus = Bus.init();
    defer bus.deinit();

    // Write to row 1, col 0
    bus.writeTextCell(1, 0, 'Z', 0x0A);
    // Write to row 24, col 0
    bus.writeTextCell(24, 0, '!', 0xFF);

    bus.scrollUp();

    // Row 1 should now be at row 0
    try std.testing.expectEqual(@as(u8, 'Z'), bus.mem[Bus.TEXT_VRAM_BASE]);
    try std.testing.expectEqual(@as(u8, 0x0A), bus.mem[Bus.TEXT_VRAM_BASE + 1]);

    // Row 24 should be cleared (space + default attr)
    const last_row_addr = Bus.TEXT_VRAM_BASE + 24 * 160;
    try std.testing.expectEqual(@as(u8, 0x20), bus.mem[last_row_addr]);
    try std.testing.expectEqual(@as(u8, 0x07), bus.mem[last_row_addr + 1]);
}

test "reset clears video and keyboard state" {
    var bus = Bus.init();
    defer bus.deinit();

    bus.video_mode = 0x13;
    bus.cursor_row = 10;
    bus.cursor_col = 40;
    _ = bus.pushKey(0x1C, 0x0D);
    bus.waiting_for_key = true;

    bus.reset();

    try std.testing.expectEqual(@as(u8, 0x03), bus.video_mode);
    try std.testing.expectEqual(@as(u8, 0), bus.cursor_row);
    try std.testing.expectEqual(@as(u8, 0), bus.cursor_col);
    try std.testing.expect(!bus.hasKey());
    try std.testing.expect(!bus.waiting_for_key);
}
