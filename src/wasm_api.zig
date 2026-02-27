const Cpu = @import("cpu.zig").Cpu;
const Bus = @import("bus.zig").Bus;
const execute = @import("execute.zig");

/// Global emulator state (lives in WASM linear memory).
var cpu: Cpu = Cpu.init();
var bus: Bus = Bus.init();

/// Packed register snapshot for JS to read.
/// 14 x u16 = 28 bytes: AX BX CX DX SI DI BP SP CS DS SS ES IP FLAGS
var reg_snapshot: [14]u16 = [_]u16{0} ** 14;

// ---- Exported API ----

/// Reset CPU and memory to initial state.
export fn init() void {
    cpu = Cpu.init();
    bus.reset();
}

/// Notify the emulator that a .COM binary has been loaded at the given offset.
/// Sets up segment registers and SP for .COM execution.
export fn load_program(offset: u16, len: u16) void {
    // .COM programs: CS=DS=ES=SS=0, IP=offset (usually 0x100)
    // SP at top of 64K segment
    cpu.cs = 0;
    cpu.ds = 0;
    cpu.es = 0;
    cpu.ss = 0;
    cpu.ip = offset;
    cpu.sp = 0xFFFE;
    // Write HLT at the return address so RET from main halts
    bus.mem[0xFFFE] = 0; // return offset low = 0x0000
    bus.mem[0xFFFF] = 0; // return offset high
    // Also push a return address on the stack pointing to 0x0000
    // where we place a HLT instruction
    bus.mem[0] = 0xF4; // HLT at 0000:0000
    _ = len;
}

/// Execute a single instruction. Returns: 0=ok, 1=halt, 2=unimplemented.
export fn step() u8 {
    if (bus.halted) return 1;
    const result = execute.step(&cpu, &bus);
    return switch (result) {
        .ok => 0,
        .halt => 1,
        .unimplemented => 2,
    };
}

/// Execute up to n instructions. Returns: 0=ok, 1=halt, 2=unimplemented.
export fn run(n: u32) u8 {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (bus.halted) return 1;
        const result = execute.step(&cpu, &bus);
        switch (result) {
            .ok => {},
            .halt => return 1,
            .unimplemented => return 2,
        }
    }
    return 0;
}

/// Write a packed register snapshot and return a pointer to it.
/// JS reads 28 bytes (14 x u16 LE) at this address.
export fn get_registers() [*]const u16 {
    reg_snapshot = .{
        cpu.ax.word,
        cpu.bx.word,
        cpu.cx.word,
        cpu.dx.word,
        cpu.si,
        cpu.di,
        cpu.bp,
        cpu.sp,
        cpu.cs,
        cpu.ds,
        cpu.ss,
        cpu.es,
        cpu.ip,
        cpu.flags.pack(),
    };
    return &reg_snapshot;
}

/// Return a pointer to the 1MB memory array.
export fn get_memory_ptr() [*]const u8 {
    return @ptrCast(bus.mem);
}

/// Return a pointer to the INT 21h output buffer.
export fn get_output_buf() [*]const u8 {
    return @ptrCast(bus.output_buf);
}

/// Return the number of bytes in the output buffer.
export fn get_output_len() u32 {
    return bus.output_len;
}

// Pull in all the modules so tests work when running this as root.
test {
    _ = @import("cpu.zig");
    _ = @import("bus.zig");
    _ = @import("decode.zig");
    _ = @import("execute.zig");
    _ = @import("flags.zig");
}
