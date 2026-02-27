const std = @import("std");
const Cpu = @import("cpu.zig").Cpu;

/// Parity lookup table: true if the byte has an even number of set bits.
/// The 8086 only checks the low byte for parity, regardless of operand size.
const parity_table: [256]bool = blk: {
    var table: [256]bool = undefined;
    for (0..256) |i| {
        const bits: u8 = @popCount(@as(u8, @intCast(i)));
        table[i] = (bits % 2 == 0);
    }
    break :blk table;
};

/// Check parity of the low byte.
pub fn parity(val: u8) bool {
    return parity_table[val];
}

/// Set SF, ZF, PF based on an 8-bit result.
pub fn setSzp8(flags: *Cpu.Flags, result: u8) void {
    flags.sign = (result & 0x80) != 0;
    flags.zero = result == 0;
    flags.parity = parity(result);
}

/// Set SF, ZF, PF based on a 16-bit result.
pub fn setSzp16(flags: *Cpu.Flags, result: u16) void {
    flags.sign = (result & 0x8000) != 0;
    flags.zero = result == 0;
    flags.parity = parity(@as(u8, @truncate(result))); // parity on low byte only
}

/// Compute all arithmetic flags for 8-bit ADD/ADC.
/// `a` and `b` are the original operands, `carry_in` is the incoming carry (0 or 1).
pub fn add8(flags: *Cpu.Flags, a: u8, b: u8, carry_in: u1) u8 {
    const full: u16 = @as(u16, a) + @as(u16, b) + @as(u16, carry_in);
    const result: u8 = @truncate(full);

    flags.carry = full > 0xFF;
    flags.overflow = ((a ^ result) & (b ^ result) & 0x80) != 0;
    flags.aux_carry = ((a & 0x0F) + (b & 0x0F) + carry_in) > 0x0F;
    setSzp8(flags, result);

    return result;
}

/// Compute all arithmetic flags for 16-bit ADD/ADC.
pub fn add16(flags: *Cpu.Flags, a: u16, b: u16, carry_in: u1) u16 {
    const full: u32 = @as(u32, a) + @as(u32, b) + @as(u32, carry_in);
    const result: u16 = @truncate(full);

    flags.carry = full > 0xFFFF;
    flags.overflow = ((a ^ result) & (b ^ result) & 0x8000) != 0;
    flags.aux_carry = ((a & 0x0F) + (b & 0x0F) + carry_in) > 0x0F;
    setSzp16(flags, result);

    return result;
}

/// Compute all arithmetic flags for 8-bit SUB/SBB/CMP.
/// Computes a - b - borrow_in.
pub fn sub8(flags: *Cpu.Flags, a: u8, b: u8, borrow_in: u1) u8 {
    const full: i16 = @as(i16, @as(i8, @bitCast(a))) - @as(i16, @as(i8, @bitCast(b))) - @as(i16, borrow_in);
    _ = full;

    const ua: u16 = @as(u16, a);
    const ub: u16 = @as(u16, b) + @as(u16, borrow_in);
    const result: u8 = a -% b -% borrow_in;

    flags.carry = ua < ub;
    flags.overflow = ((a ^ b) & (a ^ result) & 0x80) != 0;
    flags.aux_carry = (a & 0x0F) < ((b & 0x0F) + borrow_in);
    setSzp8(flags, result);

    return result;
}

/// Compute all arithmetic flags for 16-bit SUB/SBB/CMP.
pub fn sub16(flags: *Cpu.Flags, a: u16, b: u16, borrow_in: u1) u16 {
    const ua: u32 = @as(u32, a);
    const ub: u32 = @as(u32, b) + @as(u32, borrow_in);
    const result: u16 = a -% b -% borrow_in;

    flags.carry = ua < ub;
    flags.overflow = ((a ^ b) & (a ^ result) & 0x8000) != 0;
    flags.aux_carry = (a & 0x0F) < ((b & 0x0F) + borrow_in);
    setSzp16(flags, result);

    return result;
}

/// Compute flags for 8-bit INC (does NOT affect carry flag).
pub fn inc8(flags: *Cpu.Flags, val: u8) u8 {
    const result = val +% 1;
    flags.overflow = val == 0x7F;
    flags.aux_carry = (val & 0x0F) == 0x0F;
    setSzp8(flags, result);
    return result;
}

/// Compute flags for 16-bit INC (does NOT affect carry flag).
pub fn inc16(flags: *Cpu.Flags, val: u16) u16 {
    const result = val +% 1;
    flags.overflow = val == 0x7FFF;
    flags.aux_carry = (val & 0x0F) == 0x0F;
    setSzp16(flags, result);
    return result;
}

/// Compute flags for 8-bit DEC (does NOT affect carry flag).
pub fn dec8(flags: *Cpu.Flags, val: u8) u8 {
    const result = val -% 1;
    flags.overflow = val == 0x80;
    flags.aux_carry = (val & 0x0F) == 0x00;
    setSzp8(flags, result);
    return result;
}

/// Compute flags for 16-bit DEC (does NOT affect carry flag).
pub fn dec16(flags: *Cpu.Flags, val: u16) u16 {
    const result = val -% 1;
    flags.overflow = val == 0x8000;
    flags.aux_carry = (val & 0x0F) == 0x00;
    setSzp16(flags, result);
    return result;
}

/// Compute flags for 8-bit AND/OR/XOR/TEST.
/// CF and OF are cleared, AF is undefined (we clear it).
pub fn logic8(flags: *Cpu.Flags, result: u8) void {
    flags.carry = false;
    flags.overflow = false;
    flags.aux_carry = false;
    setSzp8(flags, result);
}

/// Compute flags for 16-bit AND/OR/XOR/TEST.
pub fn logic16(flags: *Cpu.Flags, result: u16) void {
    flags.carry = false;
    flags.overflow = false;
    flags.aux_carry = false;
    setSzp16(flags, result);
}

// --- Tests ---

test "parity" {
    try std.testing.expect(parity(0x00)); // 0 bits set -> even
    try std.testing.expect(!parity(0x01)); // 1 bit set -> odd
    try std.testing.expect(parity(0x03)); // 2 bits set -> even
    try std.testing.expect(!parity(0x07)); // 3 bits set -> odd
    try std.testing.expect(parity(0xFF)); // 8 bits set -> even
}

test "add8 basic" {
    var flags = Cpu.Flags{};
    const result = add8(&flags, 0x50, 0x50, 0);
    try std.testing.expectEqual(@as(u8, 0xA0), result);
    try std.testing.expect(!flags.carry);
    try std.testing.expect(flags.overflow); // 0x50 + 0x50 = 0xA0 overflows signed
    try std.testing.expect(flags.sign);
    try std.testing.expect(!flags.zero);
}

test "add8 carry" {
    var flags = Cpu.Flags{};
    const result = add8(&flags, 0xFF, 0x01, 0);
    try std.testing.expectEqual(@as(u8, 0x00), result);
    try std.testing.expect(flags.carry);
    try std.testing.expect(flags.zero);
    try std.testing.expect(!flags.sign);
}

test "sub8 borrow" {
    var flags = Cpu.Flags{};
    const result = sub8(&flags, 0x00, 0x01, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), result);
    try std.testing.expect(flags.carry); // borrow
    try std.testing.expect(flags.sign);
    try std.testing.expect(!flags.zero);
}

test "inc8 does not affect carry" {
    var flags = Cpu.Flags{};
    flags.carry = true;
    const result = inc8(&flags, 0xFF);
    try std.testing.expectEqual(@as(u8, 0x00), result);
    try std.testing.expect(flags.carry); // unchanged!
    try std.testing.expect(flags.zero);
}

test "dec8 does not affect carry" {
    var flags = Cpu.Flags{};
    flags.carry = true;
    const result = dec8(&flags, 0x00);
    try std.testing.expectEqual(@as(u8, 0xFF), result);
    try std.testing.expect(flags.carry); // unchanged!
    try std.testing.expect(flags.sign);
}

test "logic8 clears carry and overflow" {
    var flags = Cpu.Flags{};
    flags.carry = true;
    flags.overflow = true;
    logic8(&flags, 0x00);
    try std.testing.expect(!flags.carry);
    try std.testing.expect(!flags.overflow);
    try std.testing.expect(flags.zero);
    try std.testing.expect(flags.parity); // 0 has even parity
}
