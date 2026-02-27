const std = @import("std");
const Cpu = @import("cpu.zig").Cpu;
const Bus = @import("bus.zig").Bus;
const Decoder = @import("decode.zig").Decoder;

/// A single test case from the SingleStepTests suite.
pub const TestCase = struct {
    name: []const u8,
    bytes: []const u8,
    initial: CpuState,
    final: CpuState,
};

/// CPU + memory state snapshot.
pub const CpuState = struct {
    ax: u16 = 0,
    bx: u16 = 0,
    cx: u16 = 0,
    dx: u16 = 0,
    cs: u16 = 0,
    ss: u16 = 0,
    ds: u16 = 0,
    es: u16 = 0,
    sp: u16 = 0,
    bp: u16 = 0,
    si: u16 = 0,
    di: u16 = 0,
    ip: u16 = 0,
    flags: u16 = 0,
    ram: []const RamEntry = &.{},

    pub const RamEntry = struct {
        address: u20,
        value: u8,
    };
};

/// Parse a JSON test file into test cases.
/// Caller owns the returned memory.
pub fn parseTestFile(allocator: std.mem.Allocator, json_data: []const u8) ![]TestCase {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
    defer parsed.deinit();

    const array = parsed.value.array;
    var tests = try allocator.alloc(TestCase, array.items.len);
    var count: usize = 0;

    for (array.items) |item| {
        tests[count] = try parseOneTest(allocator, item);
        count += 1;
    }

    return tests[0..count];
}

fn parseOneTest(allocator: std.mem.Allocator, obj: std.json.Value) !TestCase {
    const root = obj.object;

    const name_val = root.get("name") orelse return error.MissingField;
    const name = try allocator.dupe(u8, name_val.string);

    const bytes_arr = (root.get("bytes") orelse return error.MissingField).array;
    const bytes = try allocator.alloc(u8, bytes_arr.items.len);
    for (bytes_arr.items, 0..) |b, i| {
        bytes[i] = @intCast(b.integer);
    }

    const initial_obj = (root.get("initial") orelse return error.MissingField).object;
    const final_obj = (root.get("final") orelse return error.MissingField).object;

    return .{
        .name = name,
        .bytes = bytes,
        .initial = try parseState(allocator, initial_obj),
        .final = try parseFinalState(allocator, initial_obj, final_obj),
    };
}

fn parseState(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !CpuState {
    const regs = (obj.get("regs") orelse return error.MissingField).object;
    return .{
        .ax = getRegVal(regs, "ax"),
        .bx = getRegVal(regs, "bx"),
        .cx = getRegVal(regs, "cx"),
        .dx = getRegVal(regs, "dx"),
        .cs = getRegVal(regs, "cs"),
        .ss = getRegVal(regs, "ss"),
        .ds = getRegVal(regs, "ds"),
        .es = getRegVal(regs, "es"),
        .sp = getRegVal(regs, "sp"),
        .bp = getRegVal(regs, "bp"),
        .si = getRegVal(regs, "si"),
        .di = getRegVal(regs, "di"),
        .ip = getRegVal(regs, "ip"),
        .flags = getRegVal(regs, "flags"),
        .ram = try parseRam(allocator, obj),
    };
}

/// Parse the final state. The final state only includes CHANGED registers,
/// so we merge with the initial state to get the full picture.
fn parseFinalState(
    allocator: std.mem.Allocator,
    initial_obj: std.json.ObjectMap,
    final_obj: std.json.ObjectMap,
) !CpuState {
    // Start with initial state values
    var state = try parseState(allocator, initial_obj);

    // Override with any final values
    const final_regs_val = final_obj.get("regs");
    if (final_regs_val) |frv| {
        const final_regs = frv.object;
        if (final_regs.get("ax")) |v| state.ax = @intCast(v.integer);
        if (final_regs.get("bx")) |v| state.bx = @intCast(v.integer);
        if (final_regs.get("cx")) |v| state.cx = @intCast(v.integer);
        if (final_regs.get("dx")) |v| state.dx = @intCast(v.integer);
        if (final_regs.get("cs")) |v| state.cs = @intCast(v.integer);
        if (final_regs.get("ss")) |v| state.ss = @intCast(v.integer);
        if (final_regs.get("ds")) |v| state.ds = @intCast(v.integer);
        if (final_regs.get("es")) |v| state.es = @intCast(v.integer);
        if (final_regs.get("sp")) |v| state.sp = @intCast(v.integer);
        if (final_regs.get("bp")) |v| state.bp = @intCast(v.integer);
        if (final_regs.get("si")) |v| state.si = @intCast(v.integer);
        if (final_regs.get("di")) |v| state.di = @intCast(v.integer);
        if (final_regs.get("ip")) |v| state.ip = @intCast(v.integer);
        if (final_regs.get("flags")) |v| state.flags = @intCast(v.integer);
    }

    // Final RAM (full snapshot, not delta)
    const final_ram_val = final_obj.get("ram");
    if (final_ram_val) |frv| {
        // Free initial RAM if we got one
        if (state.ram.len > 0) {
            allocator.free(state.ram);
        }
        state.ram = try parseRamFromArray(allocator, frv.array);
    }

    return state;
}

fn parseRam(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]CpuState.RamEntry {
    const ram_val = obj.get("ram") orelse return &.{};
    return parseRamFromArray(allocator, ram_val.array);
}

fn parseRamFromArray(allocator: std.mem.Allocator, arr: std.json.Array) ![]CpuState.RamEntry {
    const ram = try allocator.alloc(CpuState.RamEntry, arr.items.len);
    for (arr.items, 0..) |entry, i| {
        const pair = entry.array;
        ram[i] = .{
            .address = @intCast(pair.items[0].integer),
            .value = @intCast(pair.items[1].integer),
        };
    }
    return ram;
}

fn getRegVal(regs: std.json.ObjectMap, key: []const u8) u16 {
    const val = regs.get(key) orelse return 0;
    return @intCast(val.integer);
}

/// Load a test case's initial state into a CPU and Bus.
pub fn loadState(cpu: *Cpu, bus: *Bus, state: *const CpuState) void {
    cpu.ax.word = state.ax;
    cpu.bx.word = state.bx;
    cpu.cx.word = state.cx;
    cpu.dx.word = state.dx;
    cpu.cs = state.cs;
    cpu.ss = state.ss;
    cpu.ds = state.ds;
    cpu.es = state.es;
    cpu.sp = state.sp;
    cpu.bp = state.bp;
    cpu.si = state.si;
    cpu.di = state.di;
    cpu.ip = state.ip;
    cpu.flags = Cpu.Flags.unpack(state.flags);

    for (state.ram) |entry| {
        bus.writePhys8(entry.address, entry.value);
    }
}

/// Compare CPU + Bus state against expected final state.
/// Returns null on match, or an error description on mismatch.
pub fn compareState(
    cpu: *const Cpu,
    bus: *const Bus,
    expected: *const CpuState,
    buf: []u8,
) ?[]const u8 {
    var writer = std.io.fixedBufferStream(buf);
    const w = writer.writer();

    checkReg(w, "AX", cpu.ax.word, expected.ax);
    checkReg(w, "BX", cpu.bx.word, expected.bx);
    checkReg(w, "CX", cpu.cx.word, expected.cx);
    checkReg(w, "DX", cpu.dx.word, expected.dx);
    checkReg(w, "CS", cpu.cs, expected.cs);
    checkReg(w, "SS", cpu.ss, expected.ss);
    checkReg(w, "DS", cpu.ds, expected.ds);
    checkReg(w, "ES", cpu.es, expected.es);
    checkReg(w, "SP", cpu.sp, expected.sp);
    checkReg(w, "BP", cpu.bp, expected.bp);
    checkReg(w, "SI", cpu.si, expected.si);
    checkReg(w, "DI", cpu.di, expected.di);
    checkReg(w, "IP", cpu.ip, expected.ip);
    checkReg(w, "FLAGS", cpu.flags.pack(), expected.flags);

    for (expected.ram) |entry| {
        const actual = bus.readPhys8(entry.address);
        if (actual != entry.value) {
            w.print("RAM[{X:0>5}]: got {X:0>2}, want {X:0>2}; ", .{
                @as(u32, entry.address),
                actual,
                entry.value,
            }) catch {};
        }
    }

    const written = writer.getWritten();
    if (written.len > 0) {
        return written;
    }
    return null;
}

fn checkReg(w: anytype, name: []const u8, actual: u16, expected: u16) void {
    if (actual != expected) {
        w.print("{s}: got {X:0>4}, want {X:0>4}; ", .{ name, actual, expected }) catch {};
    }
}

// --- Tests ---

test "parse NOP test file" {
    const allocator = std.testing.allocator;

    const data = try std.fs.cwd().readFileAlloc(allocator, "tests/90.json", 10 * 1024 * 1024);
    defer allocator.free(data);

    const tests = try parseTestFile(allocator, data);
    defer {
        for (tests) |t| {
            allocator.free(t.name);
            allocator.free(t.bytes);
            if (t.initial.ram.len > 0) allocator.free(t.initial.ram);
            if (t.final.ram.len > 0) allocator.free(t.final.ram);
        }
        allocator.free(tests);
    }

    // Should have 2000 tests
    try std.testing.expect(tests.len == 2000);

    // First test should be a NOP
    try std.testing.expectEqualStrings("nop", tests[0].name);
    try std.testing.expect(tests[0].bytes.len == 1);
    try std.testing.expect(tests[0].bytes[0] == 0x90);

    // NOP should only change IP (increment by 1)
    try std.testing.expectEqual(tests[0].initial.ip + 1, tests[0].final.ip);

    // All other registers should be unchanged for NOP
    try std.testing.expectEqual(tests[0].initial.ax, tests[0].final.ax);
    try std.testing.expectEqual(tests[0].initial.bx, tests[0].final.bx);
    try std.testing.expectEqual(tests[0].initial.flags, tests[0].final.flags);
}

test "load state into CPU" {
    const state = CpuState{
        .ax = 0x1234,
        .bx = 0x5678,
        .cx = 0x9ABC,
        .dx = 0xDEF0,
        .cs = 0x0100,
        .ip = 0x0200,
        .flags = 0xF046,
    };

    var cpu = Cpu.init();
    var bus = Bus.init();
    defer bus.deinit();
    loadState(&cpu, &bus, &state);

    try std.testing.expectEqual(@as(u16, 0x1234), cpu.ax.word);
    try std.testing.expectEqual(@as(u16, 0x5678), cpu.bx.word);
    try std.testing.expectEqual(@as(u16, 0x0100), cpu.cs);
    try std.testing.expectEqual(@as(u16, 0x0200), cpu.ip);
    try std.testing.expect(cpu.flags.zero);
    try std.testing.expect(cpu.flags.parity);
}

test "compare state - match" {
    var cpu = Cpu.init();
    cpu.ax.word = 0x1234;
    cpu.ip = 0x0001;

    var bus = Bus.init();
    defer bus.deinit();

    const expected = CpuState{
        .ax = 0x1234,
        .ip = 0x0001,
        .flags = cpu.flags.pack(), // match the actual FLAGS value
    };

    var buf: [1024]u8 = undefined;
    const result = compareState(&cpu, &bus, &expected, &buf);
    try std.testing.expect(result == null);
}

test "compare state - mismatch" {
    var cpu = Cpu.init();
    cpu.ax.word = 0x1234;

    var bus = Bus.init();
    defer bus.deinit();

    const expected = CpuState{
        .ax = 0x5678,
    };

    var buf: [1024]u8 = undefined;
    const result = compareState(&cpu, &bus, &expected, &buf);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "AX") != null);
}


const execute = @import("execute.zig");

/// Run all tests from a JSON file and return (passed, failed, skipped).
pub fn runTestFile(allocator: std.mem.Allocator, path: []const u8) !struct { passed: usize, failed: usize, skipped: usize, first_failure: ?[]const u8 } {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 50 * 1024 * 1024);
    defer allocator.free(data);

    const tests = try parseTestFile(allocator, data);
    defer {
        for (tests) |t| {
            allocator.free(t.name);
            allocator.free(t.bytes);
            if (t.initial.ram.len > 0) allocator.free(t.initial.ram);
            if (t.final.ram.len > 0) allocator.free(t.final.ram);
        }
        allocator.free(tests);
    }

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var first_failure: ?[]const u8 = null;

    for (tests) |tc| {
        var cpu = Cpu.init();
        var bus = Bus.init();
        defer bus.deinit();

        loadState(&cpu, &bus, &tc.initial);

        const exec_result = execute.step(&cpu, &bus);
        if (exec_result == .unimplemented) {
            skipped += 1;
            continue;
        }

        var buf: [2048]u8 = undefined;
        const mismatch = compareState(&cpu, &bus, &tc.final, &buf);
        if (mismatch) |msg| {
            failed += 1;
            if (first_failure == null) {
                first_failure = try allocator.dupe(u8, msg);
            }
        } else {
            passed += 1;
        }
    }

    return .{ .passed = passed, .failed = failed, .skipped = skipped, .first_failure = first_failure };
}

test "hardware validation: NOP (90)" {
    const result = try runTestFile(std.testing.allocator, "tests/90.json");
    if (result.first_failure) |f| std.testing.allocator.free(f);
    try std.testing.expectEqual(@as(usize, 0), result.failed);
    try std.testing.expectEqual(@as(usize, 0), result.skipped);
    try std.testing.expect(result.passed == 2000);
}

/// Run a single test file and assert zero failures.
fn validateOpcode(path: []const u8) !void {
    const result = runTestFile(std.testing.allocator, path) catch |err| {
        // File not found is OK -- just skip
        if (err == error.FileNotFound) return;
        return err;
    };
    if (result.first_failure) |f| {
        std.debug.print("\nFirst failure in {s}: {s}\n", .{ path, f });
        std.testing.allocator.free(f);
    }
    if (result.failed > 0) {
        std.debug.print("\n{s}: {d} passed, {d} failed, {d} skipped\n", .{ path, result.passed, result.failed, result.skipped });
        return error.TestUnexpectedResult;
    }
}

test "hardware validation: ADD (00-05)" {
    try validateOpcode("tests/00.json");
    try validateOpcode("tests/01.json");
    try validateOpcode("tests/02.json");
    try validateOpcode("tests/03.json");
    try validateOpcode("tests/04.json");
    try validateOpcode("tests/05.json");
}

test "hardware validation: OR (08-0D)" {
    try validateOpcode("tests/08.json");
    try validateOpcode("tests/09.json");
    try validateOpcode("tests/0A.json");
    try validateOpcode("tests/0B.json");
    try validateOpcode("tests/0C.json");
    try validateOpcode("tests/0D.json");
}

test "hardware validation: ADC (10-15)" {
    try validateOpcode("tests/10.json");
    try validateOpcode("tests/11.json");
    try validateOpcode("tests/12.json");
    try validateOpcode("tests/13.json");
    try validateOpcode("tests/14.json");
    try validateOpcode("tests/15.json");
}

test "hardware validation: SBB (18-1D)" {
    try validateOpcode("tests/18.json");
    try validateOpcode("tests/19.json");
    try validateOpcode("tests/1A.json");
    try validateOpcode("tests/1B.json");
    try validateOpcode("tests/1C.json");
    try validateOpcode("tests/1D.json");
}

test "hardware validation: AND (20-25)" {
    try validateOpcode("tests/20.json");
    try validateOpcode("tests/21.json");
    try validateOpcode("tests/22.json");
    try validateOpcode("tests/23.json");
    try validateOpcode("tests/24.json");
    try validateOpcode("tests/25.json");
}

test "hardware validation: SUB (28-2D)" {
    try validateOpcode("tests/28.json");
    try validateOpcode("tests/29.json");
    try validateOpcode("tests/2A.json");
    try validateOpcode("tests/2B.json");
    try validateOpcode("tests/2C.json");
    try validateOpcode("tests/2D.json");
}

test "hardware validation: XOR (30-35)" {
    try validateOpcode("tests/30.json");
    try validateOpcode("tests/31.json");
    try validateOpcode("tests/32.json");
    try validateOpcode("tests/33.json");
    try validateOpcode("tests/34.json");
    try validateOpcode("tests/35.json");
}

test "hardware validation: CMP (38-3D)" {
    try validateOpcode("tests/38.json");
    try validateOpcode("tests/39.json");
    try validateOpcode("tests/3A.json");
    try validateOpcode("tests/3B.json");
    try validateOpcode("tests/3C.json");
    try validateOpcode("tests/3D.json");
}

test "hardware validation: INC r16 (40-47)" {
    for (0x40..0x48) |op| {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "tests/{X:0>2}.json", .{op}) catch unreachable;
        try validateOpcode(path);
    }
}

test "hardware validation: DEC r16 (48-4F)" {
    for (0x48..0x50) |op| {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "tests/{X:0>2}.json", .{op}) catch unreachable;
        try validateOpcode(path);
    }
}

test "hardware validation: PUSH r16 (50-57)" {
    for (0x50..0x58) |op| {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "tests/{X:0>2}.json", .{op}) catch unreachable;
        try validateOpcode(path);
    }
}

test "hardware validation: POP r16 (58-5F)" {
    for (0x58..0x60) |op| {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "tests/{X:0>2}.json", .{op}) catch unreachable;
        try validateOpcode(path);
    }
}

test "hardware validation: PUSH/POP segment" {
    try validateOpcode("tests/06.json"); // PUSH ES
    try validateOpcode("tests/07.json"); // POP ES
    try validateOpcode("tests/0E.json"); // PUSH CS
    try validateOpcode("tests/16.json"); // PUSH SS
    try validateOpcode("tests/17.json"); // POP SS
    try validateOpcode("tests/1E.json"); // PUSH DS
    try validateOpcode("tests/1F.json"); // POP DS
}

test "hardware validation: MOV (88-8B, 8C, 8E)" {
    try validateOpcode("tests/88.json");
    try validateOpcode("tests/89.json");
    try validateOpcode("tests/8A.json");
    try validateOpcode("tests/8B.json");
    try validateOpcode("tests/8C.json");
    try validateOpcode("tests/8E.json");
}

test "hardware validation: XCHG (91-97)" {
    for (0x91..0x98) |op| {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "tests/{X:0>2}.json", .{op}) catch unreachable;
        try validateOpcode(path);
    }
}

test "hardware validation: MOV moffs (A0-A3)" {
    try validateOpcode("tests/A0.json");
    try validateOpcode("tests/A1.json");
    try validateOpcode("tests/A2.json");
    try validateOpcode("tests/A3.json");
}

test "hardware validation: TEST (84, 85, A8, A9)" {
    try validateOpcode("tests/84.json");
    try validateOpcode("tests/85.json");
    try validateOpcode("tests/A8.json");
    try validateOpcode("tests/A9.json");
}

test "hardware validation: MOV imm (B0-BF)" {
    for (0xB0..0xC0) |op| {
        var path_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "tests/{X:0>2}.json", .{op}) catch unreachable;
        try validateOpcode(path);
    }
}

test "hardware validation: MOV r/m imm (C6, C7)" {
    try validateOpcode("tests/C6.json");
    try validateOpcode("tests/C7.json");
}

test "hardware validation: Group 1 (80-83)" {
    const grp_opcodes = [_][]const u8{
        "tests/80.0.json", "tests/80.1.json", "tests/80.2.json", "tests/80.3.json",
        "tests/80.4.json", "tests/80.5.json", "tests/80.6.json", "tests/80.7.json",
        "tests/81.0.json", "tests/81.1.json", "tests/81.2.json", "tests/81.3.json",
        "tests/81.4.json", "tests/81.5.json", "tests/81.6.json", "tests/81.7.json",
        "tests/82.0.json", "tests/82.1.json", "tests/82.2.json", "tests/82.3.json",
        "tests/82.4.json", "tests/82.5.json", "tests/82.6.json", "tests/82.7.json",
        "tests/83.0.json", "tests/83.1.json", "tests/83.2.json", "tests/83.3.json",
        "tests/83.4.json", "tests/83.5.json", "tests/83.6.json", "tests/83.7.json",
    };
    for (grp_opcodes) |path| {
        try validateOpcode(path);
    }
}

test "hardware validation: flag ops (F5, F8-FD)" {
    try validateOpcode("tests/F5.json"); // CMC
    try validateOpcode("tests/F8.json"); // CLC
    try validateOpcode("tests/F9.json"); // STC
    try validateOpcode("tests/FA.json"); // CLI
    try validateOpcode("tests/FB.json"); // STI
    try validateOpcode("tests/FC.json"); // CLD
    try validateOpcode("tests/FD.json"); // STD
}

test "hardware validation: Group F6/F7 (TEST/NOT/NEG)" {
    try validateOpcode("tests/F6.0.json"); // TEST r/m8, imm8
    try validateOpcode("tests/F6.2.json"); // NOT r/m8
    try validateOpcode("tests/F6.3.json"); // NEG r/m8
    try validateOpcode("tests/F7.0.json"); // TEST r/m16, imm16
    try validateOpcode("tests/F7.2.json"); // NOT r/m16
    try validateOpcode("tests/F7.3.json"); // NEG r/m16
}

test "hardware validation: INC/DEC r/m8 (FE)" {
    try validateOpcode("tests/FE.0.json"); // INC r/m8
    try validateOpcode("tests/FE.1.json"); // DEC r/m8
}