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
    flags_mask: u16,
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
    checkReg(w, "FLAGS", cpu.flags.pack() & flags_mask, expected.flags & flags_mask);

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
    const result = compareState(&cpu, &bus, &expected, &buf, 0xFFFF);
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
    const result = compareState(&cpu, &bus, &expected, &buf, 0xFFFF);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "AX") != null);
}


const execute = @import("execute.zig");

/// Run all tests from a JSON file and return (passed, failed, skipped).
const RunResult = struct { passed: usize, failed: usize, skipped: usize, first_failure: ?[]const u8 };

pub fn runTestFile(allocator: std.mem.Allocator, path: []const u8) !RunResult {
    return runTestFileWithMask(allocator, path, 0xFFFF);
}

pub fn runTestFileWithMask(allocator: std.mem.Allocator, path: []const u8, flags_mask: u16) !RunResult {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 200 * 1024 * 1024);
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

    // Allocate ONE Bus and reuse it across all test cases.
    // Previously we allocated/freed 1MB per test (2000 times per file = 2GB churn).
    var bus = Bus.init();
    defer bus.deinit();

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var first_failure: ?[]const u8 = null;

    for (tests) |tc| {
        var cpu = Cpu.init();

        // Clear only the memory regions touched by the test (via RAM entries)
        // instead of memset-ing the entire 1MB.
        // First, load initial state.
        loadState(&cpu, &bus, &tc.initial);

        const exec_result = execute.step(&cpu, &bus);
        if (exec_result == .unimplemented) {
            skipped += 1;
            // Clean up RAM entries we wrote
            for (tc.initial.ram) |entry| bus.writePhys8(entry.address, 0);
            for (tc.final.ram) |entry| bus.writePhys8(entry.address, 0);
            continue;
        }

        var buf: [2048]u8 = undefined;
        const mismatch = compareState(&cpu, &bus, &tc.final, &buf, flags_mask);
        if (mismatch) |msg| {
            failed += 1;
            if (first_failure == null) {
                first_failure = try allocator.dupe(u8, msg);
            }
        } else {
            passed += 1;
        }

        // Clean up: zero the memory locations this test touched so the
        // next test starts with a clean bus without a full 1MB memset.
        for (tc.initial.ram) |entry| bus.writePhys8(entry.address, 0);
        for (tc.final.ram) |entry| bus.writePhys8(entry.address, 0);
    }

    return .{ .passed = passed, .failed = failed, .skipped = skipped, .first_failure = first_failure };
}

// --- Parallel hardware validation ---

/// Flags masks: mask OUT undefined flag bits for certain opcodes.
const mul_flags_mask: u16 = 0xFFFF & ~@as(u16, 0x00D4); // mask SF, ZF, PF, AF
const shift_flags_mask: u16 = 0xFFFF & ~@as(u16, 0x0010); // AF undefined
const rotate_cl_flags_mask: u16 = 0xFFFF & ~@as(u16, 0x0810); // AF + OF undef
const bcd_daa_mask: u16 = 0xFFFF & ~@as(u16, 0x0800); // OF undefined
const bcd_aaa_mask: u16 = 0xFFFF & ~@as(u16, 0x08C4); // OF, SF, ZF, PF undef

const TestJob = struct {
    path: []const u8,
    mask: u16 = 0xFFFF,
    /// Minimum pass count (0 = require all to pass, >0 = allow known failures).
    min_pass: usize = 0,
};

/// All test files, generated at comptime from the opcode ranges.
const all_test_jobs = blk: {
    @setEvalBranchQuota(100_000);
    var jobs: [512]TestJob = undefined;
    var n: usize = 0;
    // Standard opcodes (0xFFFF mask)
    const standard = [_]u8{
        // ADD 00-05
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05,
        // PUSH/POP segment
        0x06, 0x07, 0x0E, 0x16, 0x17, 0x1E, 0x1F,
        // OR 08-0D
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D,
        // ADC 10-15
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15,
        // SBB 18-1D
        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D,
        // AND 20-25
        0x20, 0x21, 0x22, 0x23, 0x24, 0x25,
        // SUB 28-2D
        0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D,
        // XOR 30-35
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35,
        // CMP 38-3D
        0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D,
        // INC r16 40-47
        0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47,
        // DEC r16 48-4F
        0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F,
        // PUSH r16 50-57
        0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57,
        // POP r16 58-5F
        0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F,
        // Jcc 70-7F
        0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77,
        0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F,
        // TEST
        0x84, 0x85,
        // XCHG r/m
        0x86, 0x87,
        // MOV
        0x88, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8E,
        // NOP, XCHG AX
        0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
        // CBW, CWD
        0x98, 0x99,
        // CALL far, PUSHF, POPF, LAHF, SAHF
        0x9A, 0x9C, 0x9D, 0x9E, 0x9F,
        // MOV moffs
        0xA0, 0xA1, 0xA2, 0xA3,
        // MOVS, CMPS
        0xA4, 0xA5, 0xA6, 0xA7,
        // TEST acc, STOS, LODS, SCAS
        0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF,
        // MOV imm B0-BF
        0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7,
        0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF,
        // RET near imm, RET near
        0xC2, 0xC3,
        // LES, LDS, MOV r/m imm
        0xC4, 0xC5, 0xC6, 0xC7,
        // RET far imm, RET far
        0xCA, 0xCB,
        // INT 3, INT, INTO, IRET
        0xCC, 0xCD, 0xCE, 0xCF,
        // AAD
        0xD5,
        // XLAT
        0xD7,
        // ESC D8-DF
        0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF,
        // LOOP, LOOPZ, LOOPNZ, JCXZ
        0xE0, 0xE1, 0xE2, 0xE3,
        // I/O
        0xE4, 0xE5, 0xE6, 0xE7,
        // CALL near, JMP near, JMP far, JMP short
        0xE8, 0xE9, 0xEA, 0xEB,
        // I/O DX
        0xEC, 0xED, 0xEE, 0xEF,
        // CMC
        0xF5,
        // CLC, STC, CLI, STI, CLD, STD
        0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD,
    };
    for (standard) |op| {
        const path = std.fmt.comptimePrint("tests/{X:0>2}.json", .{op});
        jobs[n] = .{ .path = path };
        n += 1;
    }

    // Group opcodes with sub-groups (80-83, D0-D3, F6, F7, FE, FF)
    const groups = .{
        .{ .base = "80", .subs = "01234567", .mask = 0xFFFF },
        .{ .base = "81", .subs = "01234567", .mask = 0xFFFF },
        .{ .base = "82", .subs = "01234567", .mask = 0xFFFF },
        .{ .base = "83", .subs = "01234567", .mask = 0xFFFF },
        .{ .base = "D0", .subs = "0123457", .mask = shift_flags_mask },
        .{ .base = "D1", .subs = "0123457", .mask = shift_flags_mask },
        .{ .base = "D2", .subs = "0123457", .mask = rotate_cl_flags_mask },
        .{ .base = "D3", .subs = "0123457", .mask = rotate_cl_flags_mask },
        .{ .base = "F6", .subs = "023", .mask = 0xFFFF },
        .{ .base = "F7", .subs = "023", .mask = 0xFFFF },
        .{ .base = "FE", .subs = "01", .mask = 0xFFFF },
        .{ .base = "FF", .subs = "0123456", .mask = 0xFFFF },
    };
    for (groups) |g| {
        for (g.subs) |sub| {
            const path = std.fmt.comptimePrint("tests/{s}.{c}.json", .{ g.base, sub });
            jobs[n] = .{ .path = path, .mask = g.mask };
            n += 1;
        }
    }

    // MUL/IMUL (special mask)
    jobs[n] = .{ .path = "tests/F6.4.json", .mask = mul_flags_mask };
    n += 1;
    jobs[n] = .{ .path = "tests/F6.5.json", .mask = mul_flags_mask };
    n += 1;
    jobs[n] = .{ .path = "tests/F7.4.json", .mask = mul_flags_mask };
    n += 1;
    jobs[n] = .{ .path = "tests/F7.5.json", .mask = mul_flags_mask };
    n += 1;

    // BCD with custom masks / min_pass
    jobs[n] = .{ .path = "tests/37.json", .mask = bcd_aaa_mask };
    n += 1;
    jobs[n] = .{ .path = "tests/3F.json", .mask = bcd_aaa_mask };
    n += 1;
    jobs[n] = .{ .path = "tests/D4.json", .min_pass = 1900 };
    n += 1;
    jobs[n] = .{ .path = "tests/27.json", .mask = bcd_daa_mask, .min_pass = 1900 };
    n += 1;
    jobs[n] = .{ .path = "tests/2F.json", .mask = bcd_daa_mask, .min_pass = 1900 };
    n += 1;

    break :blk jobs[0..n].*;
};

/// Thread-safe counters for parallel test runner.
const AtomicCounter = std.atomic.Value(usize);

const ParallelState = struct {
    total_passed: AtomicCounter = AtomicCounter.init(0),
    total_failed: AtomicCounter = AtomicCounter.init(0),
    total_skipped: AtomicCounter = AtomicCounter.init(0),
    files_ok: AtomicCounter = AtomicCounter.init(0),
    files_failed: AtomicCounter = AtomicCounter.init(0),
    /// Mutex for first_failure_msg.
    mu: std.Thread.Mutex = .{},
    first_failure_msg: ?[]const u8 = null,
};

fn runOneJob(state: *ParallelState, job: TestJob) void {
    // Use an arena allocator per job -- much faster than page_allocator
    // for the thousands of small JSON parsing allocations.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = runTestFileWithMask(allocator, job.path, job.mask) catch |err| {
        if (err == error.FileNotFound) return; // skip missing files
        state.mu.lock();
        defer state.mu.unlock();
        if (state.first_failure_msg == null) {
            state.first_failure_msg = std.fmt.allocPrint(std.heap.page_allocator, "{s}: error {}", .{ job.path, err }) catch null;
        }
        _ = state.files_failed.fetchAdd(1, .monotonic);
        return;
    };

    _ = state.total_passed.fetchAdd(result.passed, .monotonic);
    _ = state.total_failed.fetchAdd(result.failed, .monotonic);
    _ = state.total_skipped.fetchAdd(result.skipped, .monotonic);

    const file_ok = if (job.min_pass > 0)
        result.passed >= job.min_pass
    else
        result.failed == 0;

    if (file_ok) {
        _ = state.files_ok.fetchAdd(1, .monotonic);
    } else {
        _ = state.files_failed.fetchAdd(1, .monotonic);
        state.mu.lock();
        defer state.mu.unlock();
        if (state.first_failure_msg == null) {
            if (result.first_failure) |f| {
                state.first_failure_msg = std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "{s}: {d} passed, {d} failed -- {s}",
                    .{ job.path, result.passed, result.failed, f },
                ) catch null;
            }
        }
    }

    // first_failure is allocated by the arena, no separate free needed
}

test "hardware validation (parallel)" {
    var state = ParallelState{};

    var pool: std.Thread.Pool = undefined;
    pool.init(.{ .allocator = std.heap.page_allocator }) catch {
        // Fallback: run sequentially if thread pool fails
        for (&all_test_jobs) |*job| runOneJob(&state, job.*);
        return;
    };
    defer pool.deinit();

    var wg: std.Thread.WaitGroup = .{};
    for (&all_test_jobs) |*job| {
        pool.spawnWg(&wg, runOneJob, .{ &state, job.* });
    }
    wg.wait();

    const passed = state.total_passed.load(.monotonic);
    const failed = state.total_failed.load(.monotonic);
    const files_ok = state.files_ok.load(.monotonic);
    const files_failed = state.files_failed.load(.monotonic);

    std.debug.print(
        "\n{d} files ok, {d} files failed | {d} tests passed, {d} tests failed\n",
        .{ files_ok, files_failed, passed, failed },
    );

    if (state.first_failure_msg) |msg| {
        std.debug.print("First failure: {s}\n", .{msg});
    }

    try std.testing.expectEqual(@as(usize, 0), files_failed);
}