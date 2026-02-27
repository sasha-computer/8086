const std = @import("std");
const Cpu = @import("cpu.zig").Cpu;
const Bus = @import("bus.zig").Bus;
const Decoder = @import("decode.zig").Decoder;
const EffectiveAddress = @import("decode.zig").EffectiveAddress;
const flags_mod = @import("flags.zig");

/// Execution result.
pub const ExecResult = enum {
    ok,
    halt,
    /// Unimplemented opcode.
    unimplemented,
};

/// Segment override state tracked during prefix consumption.
pub const PrefixState = struct {
    seg_override: ?u16 = null,
    rep_prefix: RepPrefix = .none,

    pub const RepPrefix = enum { none, rep, repz, repnz };
};

/// Execute a single instruction.
/// Fetches the opcode at CS:IP, decodes, and executes.
pub fn step(cpu: *Cpu, bus: *Bus) ExecResult {
    var prefix = PrefixState{};

    // Consume prefix bytes
    while (true) {
        const opcode = Decoder.fetchByte(cpu, bus);
        switch (opcode) {
            0x26 => prefix.seg_override = cpu.es, // ES:
            0x2E => prefix.seg_override = cpu.cs, // CS:
            0x36 => prefix.seg_override = cpu.ss, // SS:
            0x3E => prefix.seg_override = cpu.ds, // DS:
            0xF0 => {}, // LOCK -- acknowledge, no-op
            0xF2 => prefix.rep_prefix = .repnz,
            0xF3 => prefix.rep_prefix = .rep, // REP/REPZ
            else => return dispatch(cpu, bus, opcode, &prefix),
        }
    }
}

/// Dispatch to the handler for a given opcode.
fn dispatch(cpu: *Cpu, bus: *Bus, opcode: u8, prefix: *const PrefixState) ExecResult {
    const handler = opcode_table[opcode];
    return handler(cpu, bus, opcode, prefix);
}

/// Handler function type.
const OpHandler = *const fn (*Cpu, *Bus, u8, *const PrefixState) ExecResult;

/// Comptime-generated opcode dispatch table.
const opcode_table: [256]OpHandler = blk: {
    var table: [256]OpHandler = undefined;
    for (0..256) |i| {
        table[i] = getHandler(@intCast(i));
    }
    break :blk table;
};

fn getHandler(opcode: u8) OpHandler {
    return switch (opcode) {
        // ADD
        0x00 => makeArithModRM(.add, .byte, .rm_is_dst),
        0x01 => makeArithModRM(.add, .word, .rm_is_dst),
        0x02 => makeArithModRM(.add, .byte, .reg_is_dst),
        0x03 => makeArithModRM(.add, .word, .reg_is_dst),
        0x04 => makeArithAccImm(.add, .byte),
        0x05 => makeArithAccImm(.add, .word),

        // ADC
        0x10 => makeArithModRM(.adc, .byte, .rm_is_dst),
        0x11 => makeArithModRM(.adc, .word, .rm_is_dst),
        0x12 => makeArithModRM(.adc, .byte, .reg_is_dst),
        0x13 => makeArithModRM(.adc, .word, .reg_is_dst),
        0x14 => makeArithAccImm(.adc, .byte),
        0x15 => makeArithAccImm(.adc, .word),

        // SUB
        0x28 => makeArithModRM(.sub, .byte, .rm_is_dst),
        0x29 => makeArithModRM(.sub, .word, .rm_is_dst),
        0x2A => makeArithModRM(.sub, .byte, .reg_is_dst),
        0x2B => makeArithModRM(.sub, .word, .reg_is_dst),
        0x2C => makeArithAccImm(.sub, .byte),
        0x2D => makeArithAccImm(.sub, .word),

        // SBB
        0x18 => makeArithModRM(.sbb, .byte, .rm_is_dst),
        0x19 => makeArithModRM(.sbb, .word, .rm_is_dst),
        0x1A => makeArithModRM(.sbb, .byte, .reg_is_dst),
        0x1B => makeArithModRM(.sbb, .word, .reg_is_dst),
        0x1C => makeArithAccImm(.sbb, .byte),
        0x1D => makeArithAccImm(.sbb, .word),

        // CMP
        0x38 => makeArithModRM(.cmp, .byte, .rm_is_dst),
        0x39 => makeArithModRM(.cmp, .word, .rm_is_dst),
        0x3A => makeArithModRM(.cmp, .byte, .reg_is_dst),
        0x3B => makeArithModRM(.cmp, .word, .reg_is_dst),
        0x3C => makeArithAccImm(.cmp, .byte),
        0x3D => makeArithAccImm(.cmp, .word),

        // AND
        0x20 => makeLogicModRM(.@"and", .byte, .rm_is_dst),
        0x21 => makeLogicModRM(.@"and", .word, .rm_is_dst),
        0x22 => makeLogicModRM(.@"and", .byte, .reg_is_dst),
        0x23 => makeLogicModRM(.@"and", .word, .reg_is_dst),
        0x24 => makeLogicAccImm(.@"and", .byte),
        0x25 => makeLogicAccImm(.@"and", .word),

        // OR
        0x08 => makeLogicModRM(.@"or", .byte, .rm_is_dst),
        0x09 => makeLogicModRM(.@"or", .word, .rm_is_dst),
        0x0A => makeLogicModRM(.@"or", .byte, .reg_is_dst),
        0x0B => makeLogicModRM(.@"or", .word, .reg_is_dst),
        0x0C => makeLogicAccImm(.@"or", .byte),
        0x0D => makeLogicAccImm(.@"or", .word),

        // XOR
        0x30 => makeLogicModRM(.xor, .byte, .rm_is_dst),
        0x31 => makeLogicModRM(.xor, .word, .rm_is_dst),
        0x32 => makeLogicModRM(.xor, .byte, .reg_is_dst),
        0x33 => makeLogicModRM(.xor, .word, .reg_is_dst),
        0x34 => makeLogicAccImm(.xor, .byte),
        0x35 => makeLogicAccImm(.xor, .word),

        // INC r16
        0x40...0x47 => &opIncReg16,
        // DEC r16
        0x48...0x4F => &opDecReg16,

        // MOV r/m8, r8
        0x88 => &opMovModRM(.byte, .rm_is_dst),
        0x89 => &opMovModRM(.word, .rm_is_dst),
        0x8A => &opMovModRM(.byte, .reg_is_dst),
        0x8B => &opMovModRM(.word, .reg_is_dst),

        // MOV r/m16, sreg
        0x8C => &opMovSregToRM,
        // MOV sreg, r/m16
        0x8E => &opMovRMToSreg,

        // MOV AL/AX, moffs
        0xA0 => &opMovAccMem(.byte, .load),
        0xA1 => &opMovAccMem(.word, .load),
        // MOV moffs, AL/AX
        0xA2 => &opMovAccMem(.byte, .store),
        0xA3 => &opMovAccMem(.word, .store),

        // MOV r8, imm8
        0xB0...0xB7 => &opMovRegImm8,
        // MOV r16, imm16
        0xB8...0xBF => &opMovRegImm16,

        // MOV r/m8, imm8
        0xC6 => &opMovRMImm(.byte),
        // MOV r/m16, imm16
        0xC7 => &opMovRMImm(.word),

        // Grp1 r/m8, imm8
        0x80 => &opGrp1(.byte, .byte),
        // Grp1 r/m16, imm16
        0x81 => &opGrp1(.word, .word),
        // Grp1 r/m8, imm8 (alias)
        0x82 => &opGrp1(.byte, .byte),
        // Grp1 r/m16, imm8 (sign-extended)
        0x83 => &opGrp1(.word, .sign_ext),

        // TEST r/m8, r8
        0x84 => &opTestModRM(.byte),
        // TEST r/m16, r16
        0x85 => &opTestModRM(.word),
        // TEST AL, imm8
        0xA8 => &opTestAccImm(.byte),
        // TEST AX, imm16
        0xA9 => &opTestAccImm(.word),

        // NOT / NEG (in FE/FF group, but also F6/F7)
        0xF6 => &opGrpF6,
        0xF7 => &opGrpF7,

        // INC/DEC r/m8
        0xFE => &opGrpFE,

        // NOP
        0x90 => &opNop,

        // HLT
        0xF4 => &opHlt,

        // XCHG AX, r16 (91-97)
        0x91...0x97 => &opXchgAxReg,

        // CLC, STC, CMC, CLD, STD, CLI, STI
        0xF8 => &opClc,
        0xF9 => &opStc,
        0xF5 => &opCmc,
        0xFC => &opCld,
        0xFD => &opStd,
        0xFA => &opCli,
        0xFB => &opSti,

        // PUSH segment registers
        0x06 => &opPushSeg(0), // PUSH ES
        0x0E => &opPushSeg(1), // PUSH CS
        0x16 => &opPushSeg(2), // PUSH SS
        0x1E => &opPushSeg(3), // PUSH DS

        // POP segment registers
        0x07 => &opPopSeg(0), // POP ES
        0x17 => &opPopSeg(2), // POP SS
        0x1F => &opPopSeg(3), // POP DS

        // PUSH r16
        0x50...0x57 => &opPushReg16,
        // POP r16
        0x58...0x5F => &opPopReg16,

        else => &opUnimplemented,
    };
}

// --- Operand helpers ---

const OpSize = enum { byte, word };
const Direction = enum { rm_is_dst, reg_is_dst };
const ImmSize = enum { byte, word, sign_ext };
const AccMemDir = enum { load, store };

fn readEA(cpu: *const Cpu, bus: *const Bus, ea: EffectiveAddress, comptime size: OpSize) u16 {
    return switch (ea) {
        .register => |r| switch (size) {
            .byte => cpu.getReg8(r),
            .word => cpu.getReg16(r),
        },
        .memory => |m| switch (size) {
            .byte => bus.read8(m.segment, m.offset),
            .word => bus.read16(m.segment, m.offset),
        },
    };
}

fn writeEA(cpu: *Cpu, bus: *Bus, ea: EffectiveAddress, comptime size: OpSize, val: u16) void {
    switch (ea) {
        .register => |r| switch (size) {
            .byte => cpu.setReg8(r, @truncate(val)),
            .word => cpu.setReg16(r, val),
        },
        .memory => |m| switch (size) {
            .byte => bus.write8(m.segment, m.offset, @truncate(val)),
            .word => bus.write16(m.segment, m.offset, val),
        },
    }
}

// --- Arithmetic instruction generators ---

const ArithOp = enum { add, adc, sub, sbb, cmp };

fn doArith(comptime op: ArithOp, comptime size: OpSize, f: *Cpu.Flags, a: u16, b: u16) u16 {
    const carry_in: u1 = if (f.carry) 1 else 0;
    return switch (op) {
        .add => switch (size) {
            .byte => flags_mod.add8(f, @truncate(a), @truncate(b), 0),
            .word => flags_mod.add16(f, a, b, 0),
        },
        .adc => switch (size) {
            .byte => flags_mod.add8(f, @truncate(a), @truncate(b), carry_in),
            .word => flags_mod.add16(f, a, b, carry_in),
        },
        .sub, .cmp => switch (size) {
            .byte => flags_mod.sub8(f, @truncate(a), @truncate(b), 0),
            .word => flags_mod.sub16(f, a, b, 0),
        },
        .sbb => switch (size) {
            .byte => flags_mod.sub8(f, @truncate(a), @truncate(b), carry_in),
            .word => flags_mod.sub16(f, a, b, carry_in),
        },
    };
}

fn makeArithModRM(
    comptime op: ArithOp,
    comptime size: OpSize,
    comptime dir: Direction,
) OpHandler {
    return &struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
            const modrm_byte = Decoder.fetchByte(cpu, bus);
            const modrm = Decoder.decodeModRM(modrm_byte);
            const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);

            const rm_val = readEA(cpu, bus, ea, size);
            const reg_val: u16 = switch (size) {
                .byte => cpu.getReg8(modrm.reg),
                .word => cpu.getReg16(modrm.reg),
            };

            const a = if (dir == .rm_is_dst) rm_val else reg_val;
            const b = if (dir == .rm_is_dst) reg_val else rm_val;
            const result = doArith(op, size, &cpu.flags, a, b);

            // CMP doesn't write back
            if (op != .cmp) {
                if (dir == .rm_is_dst) {
                    writeEA(cpu, bus, ea, size, result);
                } else {
                    switch (size) {
                        .byte => cpu.setReg8(modrm.reg, @truncate(result)),
                        .word => cpu.setReg16(modrm.reg, result),
                    }
                }
            }

            return .ok;
        }
    }.handler;
}

fn makeArithAccImm(comptime op: ArithOp, comptime size: OpSize) OpHandler {
    return &struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
            const imm: u16 = switch (size) {
                .byte => Decoder.fetchByte(cpu, bus),
                .word => Decoder.fetchWord(cpu, bus),
            };
            const acc: u16 = switch (size) {
                .byte => cpu.ax.parts.lo,
                .word => cpu.ax.word,
            };

            const result = doArith(op, size, &cpu.flags, acc, imm);

            if (op != .cmp) {
                switch (size) {
                    .byte => cpu.ax.parts.lo = @truncate(result),
                    .word => cpu.ax.word = result,
                }
            }

            return .ok;
        }
    }.handler;
}

// --- Logic instruction generators ---

const LogicOp = enum { @"and", @"or", xor };

fn doLogic(comptime op: LogicOp, a: u16, b: u16) u16 {
    return switch (op) {
        .@"and" => a & b,
        .@"or" => a | b,
        .xor => a ^ b,
    };
}

fn makeLogicModRM(
    comptime op: LogicOp,
    comptime size: OpSize,
    comptime dir: Direction,
) OpHandler {
    return &struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
            const modrm_byte = Decoder.fetchByte(cpu, bus);
            const modrm = Decoder.decodeModRM(modrm_byte);
            const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);

            const rm_val = readEA(cpu, bus, ea, size);
            const reg_val: u16 = switch (size) {
                .byte => cpu.getReg8(modrm.reg),
                .word => cpu.getReg16(modrm.reg),
            };

            const a = if (dir == .rm_is_dst) rm_val else reg_val;
            const b = if (dir == .rm_is_dst) reg_val else rm_val;
            const result = doLogic(op, a, b);

            switch (size) {
                .byte => flags_mod.logic8(&cpu.flags, @truncate(result)),
                .word => flags_mod.logic16(&cpu.flags, result),
            }

            if (dir == .rm_is_dst) {
                writeEA(cpu, bus, ea, size, result);
            } else {
                switch (size) {
                    .byte => cpu.setReg8(modrm.reg, @truncate(result)),
                    .word => cpu.setReg16(modrm.reg, result),
                }
            }

            return .ok;
        }
    }.handler;
}

fn makeLogicAccImm(comptime op: LogicOp, comptime size: OpSize) OpHandler {
    return &struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
            const imm: u16 = switch (size) {
                .byte => Decoder.fetchByte(cpu, bus),
                .word => Decoder.fetchWord(cpu, bus),
            };
            const acc: u16 = switch (size) {
                .byte => cpu.ax.parts.lo,
                .word => cpu.ax.word,
            };

            const result = doLogic(op, acc, imm);

            switch (size) {
                .byte => {
                    flags_mod.logic8(&cpu.flags, @truncate(result));
                    cpu.ax.parts.lo = @truncate(result);
                },
                .word => {
                    flags_mod.logic16(&cpu.flags, result);
                    cpu.ax.word = result;
                },
            }

            return .ok;
        }
    }.handler;
}

// --- MOV instructions ---

fn opMovModRM(comptime size: OpSize, comptime dir: Direction) fn (*Cpu, *Bus, u8, *const PrefixState) ExecResult {
    return struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
            const modrm_byte = Decoder.fetchByte(cpu, bus);
            const modrm = Decoder.decodeModRM(modrm_byte);
            const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);

            if (dir == .rm_is_dst) {
                const val: u16 = switch (size) {
                    .byte => cpu.getReg8(modrm.reg),
                    .word => cpu.getReg16(modrm.reg),
                };
                writeEA(cpu, bus, ea, size, val);
            } else {
                const val = readEA(cpu, bus, ea, size);
                switch (size) {
                    .byte => cpu.setReg8(modrm.reg, @truncate(val)),
                    .word => cpu.setReg16(modrm.reg, val),
                }
            }

            return .ok;
        }
    }.handler;
}

fn opMovSregToRM(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    const modrm_byte = Decoder.fetchByte(cpu, bus);
    const modrm = Decoder.decodeModRM(modrm_byte);
    const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);
    const val = cpu.getSegReg(@truncate(modrm.reg));
    writeEA(cpu, bus, ea, .word, val);
    return .ok;
}

fn opMovRMToSreg(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    const modrm_byte = Decoder.fetchByte(cpu, bus);
    const modrm = Decoder.decodeModRM(modrm_byte);
    const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);
    const val = readEA(cpu, bus, ea, .word);
    cpu.setSegReg(@truncate(modrm.reg), val);
    return .ok;
}

fn opMovAccMem(comptime size: OpSize, comptime dir: AccMemDir) fn (*Cpu, *Bus, u8, *const PrefixState) ExecResult {
    return struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
            const offset = Decoder.fetchWord(cpu, bus);
            const seg = prefix.seg_override orelse cpu.ds;

            if (dir == .load) {
                switch (size) {
                    .byte => cpu.ax.parts.lo = bus.read8(seg, offset),
                    .word => cpu.ax.word = bus.read16(seg, offset),
                }
            } else {
                switch (size) {
                    .byte => bus.write8(seg, offset, cpu.ax.parts.lo),
                    .word => bus.write16(seg, offset, cpu.ax.word),
                }
            }

            return .ok;
        }
    }.handler;
}

fn opMovRegImm8(cpu: *Cpu, bus: *Bus, opcode: u8, _: *const PrefixState) ExecResult {
    const reg: u3 = @truncate(opcode & 0x07);
    const imm = Decoder.fetchByte(cpu, bus);
    cpu.setReg8(reg, imm);
    return .ok;
}

fn opMovRegImm16(cpu: *Cpu, bus: *Bus, opcode: u8, _: *const PrefixState) ExecResult {
    const reg: u3 = @truncate(opcode & 0x07);
    const imm = Decoder.fetchWord(cpu, bus);
    cpu.setReg16(reg, imm);
    return .ok;
}

fn opMovRMImm(comptime size: OpSize) fn (*Cpu, *Bus, u8, *const PrefixState) ExecResult {
    return struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
            const modrm_byte = Decoder.fetchByte(cpu, bus);
            const modrm = Decoder.decodeModRM(modrm_byte);
            const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);
            const imm: u16 = switch (size) {
                .byte => Decoder.fetchByte(cpu, bus),
                .word => Decoder.fetchWord(cpu, bus),
            };
            writeEA(cpu, bus, ea, size, imm);
            return .ok;
        }
    }.handler;
}

// --- Group 1 (80-83): arithmetic with immediate ---

fn opGrp1(comptime rm_size: OpSize, comptime imm_size: ImmSize) fn (*Cpu, *Bus, u8, *const PrefixState) ExecResult {
    return struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
            const modrm_byte = Decoder.fetchByte(cpu, bus);
            const modrm = Decoder.decodeModRM(modrm_byte);
            const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);
            const rm_val = readEA(cpu, bus, ea, rm_size);

            const imm: u16 = switch (imm_size) {
                .byte => Decoder.fetchByte(cpu, bus),
                .word => Decoder.fetchWord(cpu, bus),
                .sign_ext => blk: {
                    const byte: i8 = @bitCast(Decoder.fetchByte(cpu, bus));
                    break :blk @bitCast(@as(i16, byte));
                },
            };

            const result = switch (modrm.reg) {
                0 => doArith(.add, rm_size, &cpu.flags, rm_val, imm), // ADD
                1 => blk: { // OR
                    const r = rm_val | imm;
                    switch (rm_size) {
                        .byte => flags_mod.logic8(&cpu.flags, @truncate(r)),
                        .word => flags_mod.logic16(&cpu.flags, r),
                    }
                    break :blk r;
                },
                2 => doArith(.adc, rm_size, &cpu.flags, rm_val, imm), // ADC
                3 => doArith(.sbb, rm_size, &cpu.flags, rm_val, imm), // SBB
                4 => blk: { // AND
                    const r = rm_val & imm;
                    switch (rm_size) {
                        .byte => flags_mod.logic8(&cpu.flags, @truncate(r)),
                        .word => flags_mod.logic16(&cpu.flags, r),
                    }
                    break :blk r;
                },
                5 => doArith(.sub, rm_size, &cpu.flags, rm_val, imm), // SUB
                6 => blk: { // XOR
                    const r = rm_val ^ imm;
                    switch (rm_size) {
                        .byte => flags_mod.logic8(&cpu.flags, @truncate(r)),
                        .word => flags_mod.logic16(&cpu.flags, r),
                    }
                    break :blk r;
                },
                7 => doArith(.cmp, rm_size, &cpu.flags, rm_val, imm), // CMP
            };

            // CMP (reg=7) doesn't write back
            if (modrm.reg != 7) {
                writeEA(cpu, bus, ea, rm_size, result);
            }

            return .ok;
        }
    }.handler;
}

// --- TEST ---

fn opTestModRM(comptime size: OpSize) fn (*Cpu, *Bus, u8, *const PrefixState) ExecResult {
    return struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
            const modrm_byte = Decoder.fetchByte(cpu, bus);
            const modrm = Decoder.decodeModRM(modrm_byte);
            const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);

            const rm_val = readEA(cpu, bus, ea, size);
            const reg_val: u16 = switch (size) {
                .byte => cpu.getReg8(modrm.reg),
                .word => cpu.getReg16(modrm.reg),
            };

            const result = rm_val & reg_val;
            switch (size) {
                .byte => flags_mod.logic8(&cpu.flags, @truncate(result)),
                .word => flags_mod.logic16(&cpu.flags, result),
            }

            return .ok;
        }
    }.handler;
}

fn opTestAccImm(comptime size: OpSize) fn (*Cpu, *Bus, u8, *const PrefixState) ExecResult {
    return struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
            const imm: u16 = switch (size) {
                .byte => Decoder.fetchByte(cpu, bus),
                .word => Decoder.fetchWord(cpu, bus),
            };
            const acc: u16 = switch (size) {
                .byte => cpu.ax.parts.lo,
                .word => cpu.ax.word,
            };
            const result = acc & imm;
            switch (size) {
                .byte => flags_mod.logic8(&cpu.flags, @truncate(result)),
                .word => flags_mod.logic16(&cpu.flags, result),
            }
            return .ok;
        }
    }.handler;
}

// --- INC/DEC ---

fn opIncReg16(cpu: *Cpu, _: *Bus, opcode: u8, _: *const PrefixState) ExecResult {
    const reg: u3 = @truncate(opcode & 0x07);
    const val = cpu.getReg16(reg);
    cpu.setReg16(reg, flags_mod.inc16(&cpu.flags, val));
    return .ok;
}

fn opDecReg16(cpu: *Cpu, _: *Bus, opcode: u8, _: *const PrefixState) ExecResult {
    const reg: u3 = @truncate(opcode & 0x07);
    const val = cpu.getReg16(reg);
    cpu.setReg16(reg, flags_mod.dec16(&cpu.flags, val));
    return .ok;
}

// FE: INC/DEC r/m8
fn opGrpFE(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    const modrm_byte = Decoder.fetchByte(cpu, bus);
    const modrm = Decoder.decodeModRM(modrm_byte);
    const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);
    const val: u8 = @truncate(readEA(cpu, bus, ea, .byte));

    const result: u8 = switch (modrm.reg) {
        0 => flags_mod.inc8(&cpu.flags, val),
        1 => flags_mod.dec8(&cpu.flags, val),
        else => return .unimplemented,
    };
    writeEA(cpu, bus, ea, .byte, result);
    return .ok;
}

// F6: group 3 byte (TEST/NOT/NEG/MUL/IMUL/DIV/IDIV)
fn opGrpF6(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    const modrm_byte = Decoder.fetchByte(cpu, bus);
    const modrm = Decoder.decodeModRM(modrm_byte);
    const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);
    const val: u8 = @truncate(readEA(cpu, bus, ea, .byte));

    switch (modrm.reg) {
        0 => { // TEST r/m8, imm8
            const imm = Decoder.fetchByte(cpu, bus);
            flags_mod.logic8(&cpu.flags, val & imm);
        },
        2 => { // NOT r/m8
            writeEA(cpu, bus, ea, .byte, ~val);
        },
        3 => { // NEG r/m8
            const result = flags_mod.sub8(&cpu.flags, 0, val, 0);
            writeEA(cpu, bus, ea, .byte, result);
        },
        else => return .unimplemented,
    }
    return .ok;
}

// F7: group 3 word (TEST/NOT/NEG/MUL/IMUL/DIV/IDIV)
fn opGrpF7(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    const modrm_byte = Decoder.fetchByte(cpu, bus);
    const modrm = Decoder.decodeModRM(modrm_byte);
    const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);
    const val = readEA(cpu, bus, ea, .word);

    switch (modrm.reg) {
        0 => { // TEST r/m16, imm16
            const imm = Decoder.fetchWord(cpu, bus);
            flags_mod.logic16(&cpu.flags, val & imm);
        },
        2 => { // NOT r/m16
            writeEA(cpu, bus, ea, .word, ~val);
        },
        3 => { // NEG r/m16
            const result = flags_mod.sub16(&cpu.flags, 0, val, 0);
            writeEA(cpu, bus, ea, .word, result);
        },
        else => return .unimplemented,
    }
    return .ok;
}

// --- XCHG ---

fn opXchgAxReg(cpu: *Cpu, _: *Bus, opcode: u8, _: *const PrefixState) ExecResult {
    const reg: u3 = @truncate(opcode & 0x07);
    const tmp = cpu.ax.word;
    cpu.ax.word = cpu.getReg16(reg);
    cpu.setReg16(reg, tmp);
    return .ok;
}

// --- Stack operations ---

fn push16(cpu: *Cpu, bus: *Bus, val: u16) void {
    cpu.sp -%= 2;
    bus.write16(cpu.ss, cpu.sp, val);
}

fn pop16(cpu: *Cpu, bus: *Bus) u16 {
    const val = bus.read16(cpu.ss, cpu.sp);
    cpu.sp +%= 2;
    return val;
}

fn opPushSeg(comptime reg: u2) fn (*Cpu, *Bus, u8, *const PrefixState) ExecResult {
    return struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
            push16(cpu, bus, cpu.getSegReg(reg));
            return .ok;
        }
    }.handler;
}

fn opPopSeg(comptime reg: u2) fn (*Cpu, *Bus, u8, *const PrefixState) ExecResult {
    return struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
            const val = pop16(cpu, bus);
            cpu.setSegReg(reg, val);
            return .ok;
        }
    }.handler;
}

fn opPushReg16(cpu: *Cpu, bus: *Bus, opcode: u8, _: *const PrefixState) ExecResult {
    const reg: u3 = @truncate(opcode & 0x07);
    if (reg == 4) {
        // 8086 PUSH SP quirk: pushes the value of SP AFTER decrement
        cpu.sp -%= 2;
        bus.write16(cpu.ss, cpu.sp, cpu.sp);
    } else {
        push16(cpu, bus, cpu.getReg16(reg));
    }
    return .ok;
}

fn opPopReg16(cpu: *Cpu, bus: *Bus, opcode: u8, _: *const PrefixState) ExecResult {
    const reg: u3 = @truncate(opcode & 0x07);
    const val = pop16(cpu, bus);
    cpu.setReg16(reg, val);
    return .ok;
}

// --- Flag operations ---

fn opClc(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.flags.carry = false;
    return .ok;
}

fn opStc(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.flags.carry = true;
    return .ok;
}

fn opCmc(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.flags.carry = !cpu.flags.carry;
    return .ok;
}

fn opCld(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.flags.direction = false;
    return .ok;
}

fn opStd(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.flags.direction = true;
    return .ok;
}

fn opCli(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.flags.interrupt = false;
    return .ok;
}

fn opSti(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.flags.interrupt = true;
    return .ok;
}

// --- Simple instructions ---

fn opNop(_: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    return .ok;
}

fn opHlt(_: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    return .halt;
}

fn opUnimplemented(_: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    return .unimplemented;
}

// --- Tests ---

test "NOP only advances IP" {
    var cpu = Cpu.init();
    var bus = Bus.init();
    defer bus.deinit();

    cpu.cs = 0;
    cpu.ip = 0;
    bus.write8(0, 0, 0x90); // NOP

    const result = step(&cpu, &bus);
    try std.testing.expectEqual(ExecResult.ok, result);
    try std.testing.expectEqual(@as(u16, 1), cpu.ip);
}

test "HLT returns halt" {
    var cpu = Cpu.init();
    var bus = Bus.init();
    defer bus.deinit();

    bus.write8(0, 0, 0xF4); // HLT

    const result = step(&cpu, &bus);
    try std.testing.expectEqual(ExecResult.halt, result);
}

test "ADD AL, imm8" {
    var cpu = Cpu.init();
    var bus = Bus.init();
    defer bus.deinit();

    cpu.ax.parts.lo = 0x10;
    bus.write8(0, 0, 0x04); // ADD AL, imm8
    bus.write8(0, 1, 0x20); // imm8 = 0x20

    const result = step(&cpu, &bus);
    try std.testing.expectEqual(ExecResult.ok, result);
    try std.testing.expectEqual(@as(u8, 0x30), cpu.ax.parts.lo);
    try std.testing.expect(!cpu.flags.zero);
    try std.testing.expect(!cpu.flags.carry);
}

test "MOV AX, imm16" {
    var cpu = Cpu.init();
    var bus = Bus.init();
    defer bus.deinit();

    bus.write8(0, 0, 0xB8); // MOV AX, imm16
    bus.write16(0, 1, 0x1234);

    const result = step(&cpu, &bus);
    try std.testing.expectEqual(ExecResult.ok, result);
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.ax.word);
}

test "INC AX" {
    var cpu = Cpu.init();
    var bus = Bus.init();
    defer bus.deinit();

    cpu.ax.word = 0x00FF;
    bus.write8(0, 0, 0x40); // INC AX

    _ = step(&cpu, &bus);
    try std.testing.expectEqual(@as(u16, 0x0100), cpu.ax.word);
}

test "PUSH/POP AX" {
    var cpu = Cpu.init();
    var bus = Bus.init();
    defer bus.deinit();

    cpu.ss = 0x0100;
    cpu.sp = 0x0100;
    cpu.ax.word = 0xBEEF;

    // PUSH AX (0x50)
    bus.write8(0, 0, 0x50);
    _ = step(&cpu, &bus);
    try std.testing.expectEqual(@as(u16, 0x00FE), cpu.sp);

    // POP BX (0x5B)
    bus.write8(0, 1, 0x5B);
    _ = step(&cpu, &bus);
    try std.testing.expectEqual(@as(u16, 0xBEEF), cpu.bx.word);
    try std.testing.expectEqual(@as(u16, 0x0100), cpu.sp);
}
