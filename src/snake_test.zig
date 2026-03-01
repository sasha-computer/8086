const std = @import("std");
const Cpu = @import("cpu.zig").Cpu;
const Bus = @import("bus.zig").Bus;
const execute = @import("execute.zig");

const ExecResult = execute.ExecResult;

// --- Test harness ---

const SnakeState = struct {
    cpu: Cpu,
    bus: Bus,

    fn init() SnakeState {
        var bus = Bus.init();
        var cpu = Cpu.init();
        bus.intercept_bios = true;

        // Load snake.com at 0000:0100
        const file = std.fs.cwd().openFile("web/snake.com", .{}) catch
            @panic("Cannot open web/snake.com -- run tests from repo root");
        defer file.close();
        _ = file.readAll(bus.mem[0x100..]) catch @panic("Failed to read snake.com");

        // .COM setup
        cpu.cs = 0;
        cpu.ds = 0;
        cpu.es = 0;
        cpu.ss = 0;
        cpu.ip = 0x100;
        cpu.sp = 0xFFFE;
        bus.mem[0xFFFE] = 0;
        bus.mem[0xFFFF] = 0;
        bus.mem[0] = 0xF4; // HLT at 0000:0000

        return .{ .cpu = cpu, .bus = bus };
    }

    fn deinit(self: *SnakeState) void {
        self.bus.deinit();
    }

    /// Run until the next yield (INT 16h AH=01h poll with no key).
    /// Returns the number of instructions executed.
    fn runUntilYield(self: *SnakeState) u64 {
        var count: u64 = 0;
        while (count < 10_000_000) {
            const result = execute.step(&self.cpu, &self.bus);
            count += 1;
            switch (result) {
                .ok => {},
                .yield => return count,
                .halt => return count,
                .unimplemented => return count,
            }
        }
        return count;
    }

    /// Run until N yields have occurred. Returns total instructions.
    fn runYields(self: *SnakeState, n: u32) u64 {
        var total: u64 = 0;
        var yields: u32 = 0;
        while (yields < n) {
            total += self.runUntilYield();
            yields += 1;
        }
        return total;
    }

    /// Push a key into the keyboard buffer.
    fn pushKey(self: *SnakeState, scancode: u8, ascii: u8) void {
        _ = self.bus.pushKey(scancode, ascii);
    }

    /// Read a VRAM cell at (row, col). Returns {char, attr}.
    fn vramCell(self: *const SnakeState, row: u8, col: u8) struct { char: u8, attr: u8 } {
        const offset: u20 = (@as(u20, row) * 80 + @as(u20, col)) * 2;
        const addr = Bus.TEXT_VRAM_BASE + offset;
        return .{ .char = self.bus.mem[addr], .attr = self.bus.mem[addr + 1] };
    }

    /// Check if a cell looks like a snake segment (bright or dark green block/smiley).
    fn isSnake(self: *const SnakeState, row: u8, col: u8) bool {
        const cell = self.vramCell(row, col);
        // Snake head: char 0x02 (smiley), attr 0x0A (bright green)
        // Snake body: char 0xFE (block), attr 0x02 (dark green) or 0x0A (bright green)
        if (cell.char == 0x02 and cell.attr == 0x0A) return true;
        if (cell.char == 0xFE and (cell.attr == 0x02 or cell.attr == 0x0A)) return true;
        return false;
    }

    /// Find the snake head (char 0x02, attr 0x0A). Returns {row, col} or null.
    fn findHead(self: *const SnakeState) ?struct { row: u8, col: u8 } {
        for (0..25) |row| {
            for (0..80) |col| {
                const cell = self.vramCell(@intCast(row), @intCast(col));
                if (cell.char == 0x02 and cell.attr == 0x0A) {
                    return .{ .row = @intCast(row), .col = @intCast(col) };
                }
            }
        }
        return null;
    }
};

// --- Tests ---

test "snake initializes with border, body, and food" {
    var s = SnakeState.init();
    defer s.deinit();

    // Run to first yield (game loop polls keyboard after init)
    _ = s.runUntilYield();

    // Border: top-left corner should be a box-drawing char, not empty
    const tl = s.vramCell(0, 0);
    try std.testing.expect(tl.char != 0x00 and tl.char != 0x20);

    // Border: bottom-right corner
    const br = s.vramCell(24, 79);
    try std.testing.expect(br.char != 0x00 and br.char != 0x20);

    // Snake head should be at (12, 40) -- center, rightmost of initial 3 segments
    const head = s.findHead();
    try std.testing.expect(head != null);
    try std.testing.expectEqual(@as(u8, 12), head.?.row);
    try std.testing.expectEqual(@as(u8, 40), head.?.col);

    // Initial body segments at (12, 38) and (12, 39)
    try std.testing.expect(s.isSnake(12, 38));
    try std.testing.expect(s.isSnake(12, 39));
}

test "snake moves right by default" {
    var s = SnakeState.init();
    defer s.deinit();

    // First yield = after init
    _ = s.runUntilYield();

    // Second yield = after one game tick (snake moved right by 1)
    _ = s.runUntilYield();

    const head = s.findHead();
    try std.testing.expect(head != null);
    try std.testing.expectEqual(@as(u8, 12), head.?.row);
    try std.testing.expectEqual(@as(u8, 41), head.?.col);

    // After 5 more ticks, head should be at col 46
    _ = s.runYields(5);
    const head2 = s.findHead();
    try std.testing.expect(head2 != null);
    try std.testing.expectEqual(@as(u8, 12), head2.?.row);
    try std.testing.expectEqual(@as(u8, 46), head2.?.col);
}

test "snake responds to direction keys" {
    var s = SnakeState.init();
    defer s.deinit();

    // yield 1: init done, head=40
    _ = s.runUntilYield();

    // Push down arrow BEFORE first tick runs.
    // The yield returned with ZF=1 (no key). But we can push a key
    // now so the NEXT poll (at the top of game_loop) finds it.
    // However, the current yield already set ZF=1, so the game
    // will take JZ .no_key, do one right move, delay, loop back,
    // THEN find our key on the next poll.
    // So the next yield covers: right move (head=41) + down move (head at 41,13).
    s.pushKey(0x50, 0x00); // Down
    _ = s.runUntilYield();

    // Head moved right once (41,12) then down once (41,13)
    const head = s.findHead();
    try std.testing.expect(head != null);
    try std.testing.expectEqual(@as(u8, 13), head.?.row);
    try std.testing.expectEqual(@as(u8, 41), head.?.col);
}

test "snake cannot reverse direction" {
    var s = SnakeState.init();
    defer s.deinit();

    // yield 1: init done, head=40
    _ = s.runUntilYield();

    // Push left (opposite of right -- ignored). Same yield timing:
    // next yield = right move (head=41) + still right (head=42)
    // because the left key was consumed but direction unchanged.
    s.pushKey(0x4B, 0x00); // Left
    _ = s.runUntilYield();

    // Head should be at (12, 42) -- two right moves, left ignored
    const head = s.findHead();
    try std.testing.expect(head != null);
    try std.testing.expectEqual(@as(u8, 12), head.?.row);
    try std.testing.expectEqual(@as(u8, 42), head.?.col);
}

test "snake hits wall and game ends" {
    var s = SnakeState.init();
    defer s.deinit();

    // Head starts at col 40, right wall at col 78. Need 38 ticks to hit it.
    // Run until halted or waiting_for_key (game over waits for key).
    _ = s.runYields(50); // More than enough

    // Should see GAME OVER text at row 12
    // Check for 'G' 'A' 'M' 'E' at row 12
    var found_gameover = false;
    for (0..80) |col| {
        const cell = s.vramCell(12, @intCast(col));
        if (cell.char == 'G') {
            // Check "GAME OVER"
            const next = s.vramCell(12, @intCast(col + 1));
            if (next.char == 'A') {
                found_gameover = true;
                break;
            }
        }
    }
    try std.testing.expect(found_gameover);
}

test "vertical tick takes ~2x as many instructions as horizontal tick" {
    var s = SnakeState.init();
    defer s.deinit();

    // Run past init + let the snake settle into horizontal movement
    _ = s.runUntilYield(); // init
    _ = s.runUntilYield(); // tick 1 (h)
    _ = s.runUntilYield(); // tick 2 (h)

    // Measure 3 clean horizontal ticks
    const h1 = s.runUntilYield();
    const h2 = s.runUntilYield();
    const h3 = s.runUntilYield();
    const h_avg = (h1 + h2 + h3) / 3;

    // Push down arrow. Next yield will contain 1 horizontal + 1 vertical tick.
    // Skip that transitional yield, then measure clean vertical ticks.
    s.pushKey(0x50, 0x00);
    _ = s.runUntilYield(); // transitional: h + v combined

    const v1 = s.runUntilYield();
    const v2 = s.runUntilYield();
    const v3 = s.runUntilYield();
    const v_avg = (v1 + v2 + v3) / 3;

    std.debug.print("\nh ticks: {d} {d} {d} avg={d}\n", .{ h1, h2, h3, h_avg });
    std.debug.print("v ticks: {d} {d} {d} avg={d}\n", .{ v1, v2, v3, v_avg });

    const ratio = @as(f64, @floatFromInt(v_avg)) / @as(f64, @floatFromInt(h_avg));
    std.debug.print("ratio: {d:.2}\n", .{ratio});

    // Vertical should be roughly 2x horizontal.
    if (ratio < 1.7 or ratio > 2.3) {
        std.debug.print("FAIL: expected ratio ~2.0, got {d:.2}\n", .{ratio});
        return error.TestUnexpectedResult;
    }
}
