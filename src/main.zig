const std = @import("std");
const Cpu = @import("cpu.zig").Cpu;
const Bus = @import("bus.zig").Bus;

pub fn main() void {
    var bus = Bus.init();
    var cpu = Cpu.init();

    // TODO: load .COM file, run loop
    _ = &bus;
    _ = &cpu;

    std.debug.print("emu8086: no program loaded\n", .{});
}

test {
    _ = @import("cpu.zig");
    _ = @import("bus.zig");
    _ = @import("decode.zig");
    _ = @import("test_runner.zig");
    _ = @import("flags.zig");
    _ = @import("execute.zig");
}
