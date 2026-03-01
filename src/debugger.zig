const std = @import("std");
const posix = std.posix;
const Cpu = @import("cpu.zig").Cpu;
const Bus = @import("bus.zig").Bus;
const execute = @import("execute.zig");

// CGA 16-color palette mapped to ANSI 256-color indices.
const cga_to_ansi: [16]u8 = .{
    0, // 0: black
    4, // 1: blue
    2, // 2: green
    6, // 3: cyan
    1, // 4: red
    5, // 5: magenta
    3, // 6: brown
    7, // 7: light gray
    8, // 8: dark gray
    12, // 9: light blue
    10, // A: light green
    14, // B: light cyan
    9, // C: light red
    13, // D: light magenta
    11, // E: yellow
    15, // F: white
};

// CP437 to Unicode mapping for printable and box-drawing characters.
const cp437_unicode: [256]u21 = blk: {
    var table: [256]u21 = undefined;
    // Default everything to '?'
    for (0..256) |i| {
        table[i] = '?';
    }
    // ASCII printable range (0x20-0x7E) maps directly
    for (0x20..0x7F) |i| {
        table[i] = i;
    }
    // Control character range (0x00-0x1F) -- CP437 special glyphs
    table[0x00] = ' ';
    table[0x01] = 0x263A; // smiley
    table[0x02] = 0x263B; // filled smiley
    table[0x03] = 0x2665; // heart
    table[0x04] = 0x2666; // diamond
    table[0x05] = 0x2663; // club
    table[0x06] = 0x2660; // spade
    table[0x07] = 0x2022; // bullet
    table[0x08] = 0x25D8; // inverse bullet
    table[0x09] = 0x25CB; // circle
    table[0x0A] = 0x25D9; // inverse circle
    table[0x0B] = 0x2642; // male
    table[0x0C] = 0x2640; // female
    table[0x0D] = 0x266A; // note
    table[0x0E] = 0x266B; // double note
    table[0x0F] = 0x263C; // sun
    table[0x10] = 0x25BA; // right triangle
    table[0x11] = 0x25C4; // left triangle
    table[0x12] = 0x2195; // up-down arrow
    table[0x13] = 0x203C; // double exclamation
    table[0x14] = 0x00B6; // pilcrow
    table[0x15] = 0x00A7; // section
    table[0x16] = 0x25AC; // filled rectangle
    table[0x17] = 0x21A8; // up-down arrow with base
    table[0x18] = 0x2191; // up arrow
    table[0x19] = 0x2193; // down arrow
    table[0x1A] = 0x2192; // right arrow
    table[0x1B] = 0x2190; // left arrow
    table[0x1C] = 0x221F; // right angle
    table[0x1D] = 0x2194; // left-right arrow
    table[0x1E] = 0x25B2; // up triangle
    table[0x1F] = 0x25BC; // down triangle
    table[0x7F] = 0x2302; // house
    // Box drawing
    table[0xB3] = 0x2502; // vertical line
    table[0xBA] = 0x2551; // double vertical
    table[0xC4] = 0x2500; // horizontal line
    table[0xCD] = 0x2550; // double horizontal
    table[0xC9] = 0x2554; // double top-left
    table[0xBB] = 0x2557; // double top-right
    table[0xC8] = 0x255A; // double bottom-left
    table[0xBC] = 0x255D; // double bottom-right
    table[0xDA] = 0x250C; // single top-left
    table[0xBF] = 0x2510; // single top-right
    table[0xC0] = 0x2514; // single bottom-left
    table[0xD9] = 0x2518; // single bottom-right
    table[0xC3] = 0x251C; // left tee
    table[0xB4] = 0x2524; // right tee
    table[0xC2] = 0x252C; // top tee
    table[0xC1] = 0x2534; // bottom tee
    table[0xC5] = 0x253C; // cross
    // Block elements
    table[0xDB] = 0x2588; // full block
    table[0xDC] = 0x2584; // lower half block
    table[0xDD] = 0x258C; // left half block
    table[0xDE] = 0x2590; // right half block
    table[0xDF] = 0x2580; // upper half block
    table[0xB0] = 0x2591; // light shade
    table[0xB1] = 0x2592; // medium shade
    table[0xB2] = 0x2593; // dark shade
    table[0xFE] = 0x25A0; // filled square
    break :blk table;
};

const RunMode = enum {
    continuous,
    step,
    paused,
};

const STDOUT_FD = posix.STDOUT_FILENO;
const STDIN_FD = posix.STDIN_FILENO;

fn writeAll(data: []const u8) void {
    var written: usize = 0;
    while (written < data.len) {
        written += posix.write(STDOUT_FD, data[written..]) catch return;
    }
}

fn printFmt(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeAll(s);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    if (args.len < 2) {
        const usage =
            "Usage: emu8086-dbg <program.com> [--step] [--headless N] [--key INSN:SC:ASCII ...]\n" ++
            "\nControls (interactive mode):\n" ++
            "  Arrow keys, letters, digits  -- forwarded to 8086\n" ++
            "  Ctrl-C or Ctrl-Q             -- quit\n" ++
            "  Ctrl-P                       -- toggle pause/run\n" ++
            "  Ctrl-S                       -- single step (when paused)\n" ++
            "  Ctrl-R                       -- dump registers\n" ++
            "  Ctrl-D                       -- toggle debug trace\n" ++
            "\n  --headless N       Run N instructions then dump VRAM + registers (no TTY)\n" ++
            "  --key INSN:SC:ASCII  Inject key at instruction count (headless only, repeatable)\n";
        writeAll(usage);
        std.process.exit(1);
    }

    const KeyInject = struct {
        at: u64,
        scancode: u8,
        ascii: u8,
    };

    var step_mode = false;
    var headless_count: ?u64 = null;
    var key_injects: [64]KeyInject = undefined;
    var key_inject_count: usize = 0;
    var i_arg: usize = 2;
    while (i_arg < args.len) : (i_arg += 1) {
        if (std.mem.eql(u8, args[i_arg], "--step")) {
            step_mode = true;
        } else if (std.mem.eql(u8, args[i_arg], "--headless")) {
            i_arg += 1;
            if (i_arg < args.len) {
                headless_count = std.fmt.parseInt(u64, args[i_arg], 10) catch 1_000_000;
            } else {
                headless_count = 1_000_000;
            }
        } else if (std.mem.eql(u8, args[i_arg], "--key")) {
            i_arg += 1;
            if (i_arg < args.len and key_inject_count < 64) {
                // Parse INSN:SCANCODE:ASCII
                var it = std.mem.splitScalar(u8, args[i_arg], ':');
                const at_str = it.next() orelse continue;
                const sc_str = it.next() orelse continue;
                const ascii_str = it.next() orelse continue;
                key_injects[key_inject_count] = .{
                    .at = std.fmt.parseInt(u64, at_str, 10) catch continue,
                    .scancode = std.fmt.parseInt(u8, sc_str, 10) catch continue,
                    .ascii = std.fmt.parseInt(u8, ascii_str, 10) catch continue,
                };
                key_inject_count += 1;
            }
        }
    }

    // Sort key injects by instruction count
    const injects = key_injects[0..key_inject_count];
    std.mem.sort(KeyInject, injects, {}, struct {
        fn lessThan(_: void, a: KeyInject, b: KeyInject) bool {
            return a.at < b.at;
        }
    }.lessThan);

    // Load .COM file
    const file = try std.fs.cwd().openFile(args[1], .{});
    defer file.close();
    const file_size = try file.getEndPos();
    if (file_size > 65280) {
        std.debug.print("File too large for .COM format (max 65280 bytes, got {d})\n", .{file_size});
        std.process.exit(1);
    }

    var bus = Bus.init();
    defer bus.deinit();
    var cpu = Cpu.init();

    // Enable BIOS interception for native debugger
    bus.intercept_bios = true;

    // Load program at 0000:0100
    const program_data = bus.mem[0x100..];
    _ = try file.readAll(program_data);

    // Set up .COM execution environment
    cpu.cs = 0;
    cpu.ds = 0;
    cpu.es = 0;
    cpu.ss = 0;
    cpu.ip = 0x100;
    cpu.sp = 0xFFFE;
    bus.mem[0xFFFE] = 0;
    bus.mem[0xFFFF] = 0;
    bus.mem[0] = 0xF4; // HLT at 0000:0000

    // Headless mode: run N instructions, dump state, exit
    if (headless_count) |max_insns| {
        var total_insns: u64 = 0;
        var next_inject: usize = 0;
        while (total_insns < max_insns and !bus.halted) {
            // Inject keys at scheduled instruction counts
            while (next_inject < injects.len and injects[next_inject].at <= total_insns) {
                _ = bus.pushKey(injects[next_inject].scancode, injects[next_inject].ascii);
                next_inject += 1;
            }
            const result = execute.step(&cpu, &bus);
            total_insns += 1;
            switch (result) {
                .ok => {},
                .halt => break,
                .unimplemented => {
                    std.debug.print("UNIMPLEMENTED at {X:0>4}:{X:0>4} after {d} insns\n", .{ cpu.cs, cpu.ip, total_insns });
                    break;
                },
                .yield => {},
            }
        }
        dumpVRAMText(bus);
        std.debug.print("\n--- Registers after {d} instructions ---\n", .{total_insns});
        std.debug.print("AX={X:0>4} BX={X:0>4} CX={X:0>4} DX={X:0>4} SI={X:0>4} DI={X:0>4} SP={X:0>4} BP={X:0>4}\n", .{
            cpu.ax.word, cpu.bx.word, cpu.cx.word, cpu.dx.word, cpu.si, cpu.di, cpu.sp, cpu.bp,
        });
        std.debug.print("CS={X:0>4} DS={X:0>4} SS={X:0>4} ES={X:0>4} IP={X:0>4} FLAGS={X:0>4}\n", .{
            cpu.cs, cpu.ds, cpu.ss, cpu.es, cpu.ip, cpu.flags.pack(),
        });
        std.debug.print("halted={} waiting_for_key={}\n", .{ bus.halted, bus.waiting_for_key });
        if (bus.output_len > 0) {
            std.debug.print("\n--- INT 21h Output ({d} bytes) ---\n", .{bus.output_len});
            std.debug.print("{s}\n", .{bus.output_buf[0..bus.output_len]});
        }
        return;
    }

    // Interactive mode
    const original_termios = try enableRawMode();
    defer disableRawMode(original_termios) catch {};

    writeAll("\x1b[?25l\x1b[2J");
    defer {
        writeAll("\x1b[?25h\x1b[0m\x1b[2J\x1b[H");
    }

    var mode: RunMode = if (step_mode) .paused else .continuous;
    var debug_trace = false;
    var prev_vram: [4000]u8 = [_]u8{0} ** 4000;
    var frame_count: u64 = 0;
    var total_insns: u64 = 0;

    while (!bus.halted) {
        pollKeyboard(&bus, &mode, &debug_trace);

        switch (mode) {
            .continuous => {
                // Run instructions until yield/halt/batch limit
                const batch: u32 = 500_000;
                var i: u32 = 0;
                var yielded = false;
                while (i < batch) : (i += 1) {
                    if (bus.halted) break;
                    const result = execute.step(&cpu, &bus);
                    total_insns += 1;
                    switch (result) {
                        .ok => {},
                        .halt => break,
                        .unimplemented => {
                            renderVRAM(bus, &prev_vram);
                            printFmt("\x1b[27;1H\x1b[0m[UNIMPLEMENTED OPCODE at {X:0>4}:{X:0>4}]\n", .{ cpu.cs, cpu.ip });
                            mode = .paused;
                            break;
                        },
                        .yield => {
                            // Game is polling keyboard -- break to check for input
                            // but DON'T sleep, re-enter immediately after polling
                            yielded = true;
                            break;
                        },
                    }
                }

                frame_count += 1;
                renderVRAM(bus, &prev_vram);

                if (debug_trace and frame_count % 30 == 0) {
                    printRegisters(cpu, total_insns);
                }

                // Only sleep when we ran a full batch (not yielded).
                // When yielded, just do a short sleep to avoid busy-spinning
                // while giving the terminal time to deliver input.
                if (yielded) {
                    std.Thread.sleep(5 * std.time.ns_per_ms);
                } else {
                    std.Thread.sleep(33 * std.time.ns_per_ms);
                }
            },
            .step => {
                const result = execute.step(&cpu, &bus);
                total_insns += 1;
                renderVRAM(bus, &prev_vram);
                printRegisters(cpu, total_insns);
                switch (result) {
                    .ok => {},
                    .halt => {},
                    .unimplemented => {
                        printFmt("\x1b[28;1H\x1b[0m[UNIMPLEMENTED]\n", .{});
                    },
                    .yield => {},
                }
                mode = .paused;
            },
            .paused => {
                std.Thread.sleep(50 * std.time.ns_per_ms);
            },
        }
    }

    renderVRAM(bus, &prev_vram);
    printRegisters(cpu, total_insns);
    writeAll("\x1b[29;1H\x1b[0m[HALTED - press any key to exit]\n");

    var exit_buf: [1]u8 = undefined;
    _ = posix.read(STDIN_FD, &exit_buf) catch {};
}

fn dumpVRAMText(bus: Bus) void {
    const vram = bus.mem[Bus.TEXT_VRAM_BASE .. Bus.TEXT_VRAM_BASE + 4000];
    for (0..25) |row| {
        var line: [80]u8 = undefined;
        for (0..80) |col| {
            const ch = vram[(row * 80 + col) * 2];
            line[col] = if (ch >= 0x20 and ch < 0x7F) ch else '.';
        }
        // Trim trailing spaces
        var end: usize = 80;
        while (end > 0 and line[end - 1] == ' ') end -= 1;
        std.debug.print("{s}\n", .{line[0..end]});
    }
}

fn enableRawMode() !posix.termios {
    const original = try posix.tcgetattr(STDIN_FD);
    var raw = original;
    raw.lflag = .{};
    raw.iflag = .{};
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(STDIN_FD, .FLUSH, raw);
    return original;
}

fn disableRawMode(original: posix.termios) !void {
    try posix.tcsetattr(STDIN_FD, .FLUSH, original);
}

fn pollKeyboard(bus: *Bus, mode: *RunMode, debug_trace: *bool) void {
    var buf: [16]u8 = undefined;
    const n = posix.read(STDIN_FD, &buf) catch return;
    if (n == 0) return;

    var i: usize = 0;
    while (i < n) {
        const ch = buf[i];
        i += 1;

        // Ctrl-C or Ctrl-Q: quit
        if (ch == 0x03 or ch == 0x11) {
            bus.halted = true;
            return;
        }
        // Ctrl-P: toggle pause
        if (ch == 0x10) {
            mode.* = if (mode.* == .paused) .continuous else .paused;
            return;
        }
        // Ctrl-S: single step
        if (ch == 0x13) {
            mode.* = .step;
            return;
        }
        // Ctrl-R / Ctrl-D: toggle debug trace
        if (ch == 0x12 or ch == 0x04) {
            debug_trace.* = !debug_trace.*;
            return;
        }

        // Escape sequences (arrow keys)
        if (ch == 0x1b) {
            if (i < n and buf[i] == '[') {
                i += 1;
                if (i < n) {
                    const arrow = buf[i];
                    i += 1;
                    switch (arrow) {
                        'A' => _ = bus.pushKey(0x48, 0x00), // Up
                        'B' => _ = bus.pushKey(0x50, 0x00), // Down
                        'C' => _ = bus.pushKey(0x4D, 0x00), // Right
                        'D' => _ = bus.pushKey(0x4B, 0x00), // Left
                        else => {},
                    }
                    continue;
                }
            }
            _ = bus.pushKey(0x01, 0x1B);
            continue;
        }

        // Regular keys
        const scancode = asciiToScancode(ch);
        _ = bus.pushKey(scancode, ch);
    }
}

fn asciiToScancode(ascii: u8) u8 {
    return switch (ascii) {
        '1'...'9' => ascii - '1' + 0x02,
        '0' => 0x0B,
        'a'...'z' => switch (ascii) {
            'a' => 0x1E,
            'b' => 0x30,
            'c' => 0x2E,
            'd' => 0x20,
            'e' => 0x12,
            'f' => 0x21,
            'g' => 0x22,
            'h' => 0x23,
            'i' => 0x17,
            'j' => 0x24,
            'k' => 0x25,
            'l' => 0x26,
            'm' => 0x32,
            'n' => 0x31,
            'o' => 0x18,
            'p' => 0x19,
            'q' => 0x10,
            'r' => 0x13,
            's' => 0x1F,
            't' => 0x14,
            'u' => 0x16,
            'v' => 0x2F,
            'w' => 0x11,
            'x' => 0x2D,
            'y' => 0x15,
            'z' => 0x2C,
            else => unreachable,
        },
        ' ' => 0x39,
        0x0D => 0x1C,
        0x08 => 0x0E,
        0x09 => 0x0F,
        else => 0x00,
    };
}

fn renderVRAM(bus: Bus, prev_vram: *[4000]u8) void {
    const vram = bus.mem[Bus.TEXT_VRAM_BASE .. Bus.TEXT_VRAM_BASE + 4000];

    // Check if anything changed
    if (std.mem.eql(u8, vram, prev_vram)) return;

    var buf: [65536]u8 = undefined;
    var pos: usize = 0;

    var last_fg: u8 = 0xFF;
    var last_bg: u8 = 0xFF;

    for (0..25) |row| {
        // Move cursor to row (1-indexed)
        const cursor = std.fmt.bufPrint(buf[pos..], "\x1b[{d};1H", .{row + 1}) catch break;
        pos += cursor.len;

        for (0..80) |col| {
            const offset = (row * 80 + col) * 2;
            const ch = vram[offset];
            const attr = vram[offset + 1];
            const fg = attr & 0x0F;
            const bg = (attr >> 4) & 0x0F;

            if (fg != last_fg or bg != last_bg) {
                const color = std.fmt.bufPrint(buf[pos..], "\x1b[38;5;{d};48;5;{d}m", .{ cga_to_ansi[fg], cga_to_ansi[bg] }) catch break;
                pos += color.len;
                last_fg = fg;
                last_bg = bg;
            }

            // Encode CP437 character as UTF-8
            const codepoint = cp437_unicode[ch];
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 1;
            if (pos + len > buf.len) break;
            @memcpy(buf[pos..][0..len], utf8_buf[0..len]);
            pos += len;
        }
    }

    // Reset
    const reset = "\x1b[0m";
    if (pos + reset.len <= buf.len) {
        @memcpy(buf[pos..][0..reset.len], reset);
        pos += reset.len;
    }

    writeAll(buf[0..pos]);
    @memcpy(prev_vram, vram);
}

fn printRegisters(cpu: Cpu, total_insns: u64) void {
    printFmt(
        "\x1b[27;1H\x1b[0m\x1b[K AX={X:0>4} BX={X:0>4} CX={X:0>4} DX={X:0>4} SI={X:0>4} DI={X:0>4} SP={X:0>4} BP={X:0>4} IP={X:0>4} [{d} insns]",
        .{ cpu.ax.word, cpu.bx.word, cpu.cx.word, cpu.dx.word, cpu.si, cpu.di, cpu.sp, cpu.bp, cpu.ip, total_insns },
    );
    printFmt(
        "\x1b[28;1H\x1b[K CS={X:0>4} DS={X:0>4} SS={X:0>4} ES={X:0>4} {s}{s}{s}{s}{s}{s}{s}{s}{s}",
        .{
            cpu.cs,
            cpu.ds,
            cpu.ss,
            cpu.es,
            @as([]const u8, if (cpu.flags.overflow) "O" else "."),
            @as([]const u8, if (cpu.flags.direction) "D" else "."),
            @as([]const u8, if (cpu.flags.interrupt) "I" else "."),
            @as([]const u8, if (cpu.flags.sign) "S" else "."),
            @as([]const u8, if (cpu.flags.zero) "Z" else "."),
            @as([]const u8, if (cpu.flags.aux_carry) "A" else "."),
            @as([]const u8, if (cpu.flags.parity) "P" else "."),
            @as([]const u8, if (cpu.flags.carry) "C" else "."),
            @as([]const u8, if (cpu.flags.trap) "T" else "."),
        },
    );
}
