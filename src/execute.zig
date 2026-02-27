const std = @import("std");
const Cpu = @import("cpu.zig").Cpu;
const Bus = @import("bus.zig").Bus;
const Decoder = @import("decode.zig").Decoder;
const EffectiveAddress = @import("decode.zig").EffectiveAddress;
const flags_mod = @import("flags.zig");
const builtin = @import("builtin");

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

        // --- Control Flow ---

        // JMP short (EB)
        0xEB => &opJmpShort,
        // JMP near (E9)
        0xE9 => &opJmpNear,
        // JMP far (EA)
        0xEA => &opJmpFar,

        // Jcc short
        0x70 => &makeJcc(0), // JO
        0x71 => &makeJcc(1), // JNO
        0x72 => &makeJcc(2), // JB/JC/JNAE
        0x73 => &makeJcc(3), // JNB/JNC/JAE
        0x74 => &makeJcc(4), // JZ/JE
        0x75 => &makeJcc(5), // JNZ/JNE
        0x76 => &makeJcc(6), // JBE/JNA
        0x77 => &makeJcc(7), // JNBE/JA
        0x78 => &makeJcc(8), // JS
        0x79 => &makeJcc(9), // JNS
        0x7A => &makeJcc(10), // JP/JPE
        0x7B => &makeJcc(11), // JNP/JPO
        0x7C => &makeJcc(12), // JL/JNGE
        0x7D => &makeJcc(13), // JNL/JGE
        0x7E => &makeJcc(14), // JLE/JNG
        0x7F => &makeJcc(15), // JNLE/JG

        // LOOP/LOOPx/JCXZ
        0xE0 => &opLoopnz,
        0xE1 => &opLoopz,
        0xE2 => &opLoop,
        0xE3 => &opJcxz,

        // CALL near (E8)
        0xE8 => &opCallNear,
        // RET near (C3)
        0xC3 => &opRetNear,
        // RET near imm16 (C2)
        0xC2 => &opRetNearImm,
        // CALL far (9A)
        0x9A => &opCallFar,
        // RET far (CB)
        0xCB => &opRetFar,
        // RET far imm16 (CA)
        0xCA => &opRetFarImm,

        // INT imm8 (CD)
        0xCD => &opInt,
        // INT 3 (CC)
        0xCC => &opInt3,
        // INTO (CE)
        0xCE => &opInto,
        // IRET (CF)
        0xCF => &opIret,

        // --- Data Movement & Misc (Phase 5) ---

        // XCHG r/m8, r8 (86)
        0x86 => &opXchgRM(.byte),
        // XCHG r/m16, r16 (87)
        0x87 => &opXchgRM(.word),

        // LEA (8D)
        0x8D => &opLea,
        // LDS (C5)
        0xC5 => &opLds,
        // LES (C4)
        0xC4 => &opLes,

        // LAHF (9F)
        0x9F => &opLahf,
        // SAHF (9E)
        0x9E => &opSahf,
        // PUSHF (9C)
        0x9C => &opPushf,
        // POPF (9D)
        0x9D => &opPopf,

        // CBW (98)
        0x98 => &opCbw,
        // CWD (99)
        0x99 => &opCwd,
        // XLAT (D7)
        0xD7 => &opXlat,

        // FF group: INC/DEC/CALL/JMP/PUSH r/m16
        0xFF => &opGrpFF,

        // --- Shifts/Rotates (D0-D3) ---
        0xD0 => &opGrpShift(.byte, .one),  // shift/rotate r/m8, 1
        0xD1 => &opGrpShift(.word, .one),  // shift/rotate r/m16, 1
        0xD2 => &opGrpShift(.byte, .cl),   // shift/rotate r/m8, CL
        0xD3 => &opGrpShift(.word, .cl),   // shift/rotate r/m16, CL

        // --- BCD ---
        0x27 => &opDaa,  // DAA
        0x2F => &opDas,  // DAS
        0x37 => &opAaa,  // AAA
        0x3F => &opAas,  // AAS
        0xD4 => &opAam,  // AAM
        0xD5 => &opAad,  // AAD

        // --- String operations ---
        0xA4 => &opMovsb,
        0xA5 => &opMovsw,
        0xA6 => &opCmpsb,
        0xA7 => &opCmpsw,
        0xAA => &opStosb,
        0xAB => &opStosw,
        0xAC => &opLodsb,
        0xAD => &opLodsw,
        0xAE => &opScasb,
        0xAF => &opScasw,

        // --- I/O ---
        0xE4 => &opInAlImm,
        0xE5 => &opInAxImm,
        0xE6 => &opOutImmAl,
        0xE7 => &opOutImmAx,
        0xEC => &opInAlDx,
        0xED => &opInAxDx,
        0xEE => &opOutDxAl,
        0xEF => &opOutDxAx,

        // WAIT (no-op for emulation)
        0x9B => &opNop,

        // ESC (FPU escape, D8-DF -- consume ModR/M and ignore)
        0xD8...0xDF => &opEsc,

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
        4 => { // MUL r/m8
            const result: u16 = @as(u16, cpu.ax.parts.lo) * @as(u16, val);
            cpu.ax.word = result;
            const hi_nonzero = cpu.ax.parts.hi != 0;
            cpu.flags.carry = hi_nonzero;
            cpu.flags.overflow = hi_nonzero;
            // SF, ZF, AF, PF are undefined on 8086 but hardware sets them
            flags_mod.setSzp8(&cpu.flags, cpu.ax.parts.lo);
            cpu.flags.sign = (cpu.ax.parts.hi & 0x80) != 0;
            cpu.flags.aux_carry = false;
        },
        5 => { // IMUL r/m8
            const result: i16 = @as(i16, @as(i8, @bitCast(cpu.ax.parts.lo))) * @as(i16, @as(i8, @bitCast(val)));
            cpu.ax.word = @bitCast(result);
            // CF=OF=1 if sign extension of AL != AX
            const sign_ext: i16 = @as(i8, @bitCast(cpu.ax.parts.lo));
            const ext_differs = @as(u16, @bitCast(sign_ext)) != cpu.ax.word;
            cpu.flags.carry = ext_differs;
            cpu.flags.overflow = ext_differs;
            flags_mod.setSzp8(&cpu.flags, cpu.ax.parts.lo);
            cpu.flags.sign = (cpu.ax.parts.hi & 0x80) != 0;
            cpu.flags.aux_carry = false;
        },
        6 => { // DIV r/m8
            if (val == 0) {
                doInterrupt(cpu, bus, 0);
                return .ok;
            }
            const dividend = cpu.ax.word;
            const quotient = dividend / @as(u16, val);
            if (quotient > 0xFF) {
                doInterrupt(cpu, bus, 0);
                return .ok;
            }
            cpu.ax.parts.lo = @truncate(quotient);
            cpu.ax.parts.hi = @truncate(dividend % @as(u16, val));
        },
        7 => { // IDIV r/m8
            if (val == 0) {
                doInterrupt(cpu, bus, 0);
                return .ok;
            }
            const dividend: i16 = @bitCast(cpu.ax.word);
            const divisor: i16 = @as(i8, @bitCast(val));
            if (divisor == 0) {
                doInterrupt(cpu, bus, 0);
                return .ok;
            }
            const quotient = @divTrunc(dividend, divisor);
            if (quotient > 127 or quotient < -128) {
                doInterrupt(cpu, bus, 0);
                return .ok;
            }
            cpu.ax.parts.lo = @bitCast(@as(i8, @truncate(quotient)));
            cpu.ax.parts.hi = @bitCast(@as(i8, @truncate(@rem(dividend, divisor))));
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
        4 => { // MUL r/m16
            const result: u32 = @as(u32, cpu.ax.word) * @as(u32, val);
            cpu.ax.word = @truncate(result);
            cpu.dx.word = @truncate(result >> 16);
            const hi_nonzero = cpu.dx.word != 0;
            cpu.flags.carry = hi_nonzero;
            cpu.flags.overflow = hi_nonzero;
            flags_mod.setSzp16(&cpu.flags, cpu.ax.word);
            cpu.flags.sign = (cpu.dx.word & 0x8000) != 0;
            cpu.flags.aux_carry = false;
        },
        5 => { // IMUL r/m16
            const result: i32 = @as(i32, @as(i16, @bitCast(cpu.ax.word))) * @as(i32, @as(i16, @bitCast(val)));
            const uresult: u32 = @bitCast(result);
            cpu.ax.word = @truncate(uresult);
            cpu.dx.word = @truncate(uresult >> 16);
            const sign_ext: i32 = @as(i16, @bitCast(cpu.ax.word));
            const ext_differs = @as(u32, @bitCast(sign_ext)) != uresult;
            cpu.flags.carry = ext_differs;
            cpu.flags.overflow = ext_differs;
            flags_mod.setSzp16(&cpu.flags, cpu.ax.word);
            cpu.flags.sign = (cpu.dx.word & 0x8000) != 0;
            cpu.flags.aux_carry = false;
        },
        6 => { // DIV r/m16
            if (val == 0) {
                doInterrupt(cpu, bus, 0);
                return .ok;
            }
            const dividend: u32 = @as(u32, cpu.dx.word) << 16 | @as(u32, cpu.ax.word);
            const quotient = dividend / @as(u32, val);
            if (quotient > 0xFFFF) {
                doInterrupt(cpu, bus, 0);
                return .ok;
            }
            cpu.ax.word = @truncate(quotient);
            cpu.dx.word = @truncate(dividend % @as(u32, val));
        },
        7 => { // IDIV r/m16
            if (val == 0) {
                doInterrupt(cpu, bus, 0);
                return .ok;
            }
            const dividend: i32 = (@as(i32, @as(i16, @bitCast(cpu.dx.word))) << 16) | @as(i32, @intCast(cpu.ax.word));
            const divisor: i32 = @as(i16, @bitCast(val));
            if (divisor == 0) {
                doInterrupt(cpu, bus, 0);
                return .ok;
            }
            const quotient = @divTrunc(dividend, divisor);
            if (quotient > 32767 or quotient < -32768) {
                doInterrupt(cpu, bus, 0);
                return .ok;
            }
            cpu.ax.word = @bitCast(@as(i16, @truncate(quotient)));
            cpu.dx.word = @bitCast(@as(i16, @truncate(@rem(dividend, divisor))));
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

// --- Control Flow ---

fn opJmpShort(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const disp: i8 = @bitCast(Decoder.fetchByte(cpu, bus));
    cpu.ip = cpu.ip +% @as(u16, @bitCast(@as(i16, disp)));
    return .ok;
}

fn opJmpNear(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const disp: i16 = @bitCast(Decoder.fetchWord(cpu, bus));
    cpu.ip = cpu.ip +% @as(u16, @bitCast(disp));
    return .ok;
}

fn opJmpFar(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const offset = Decoder.fetchWord(cpu, bus);
    const segment = Decoder.fetchWord(cpu, bus);
    cpu.ip = offset;
    cpu.cs = segment;
    return .ok;
}

fn evalCondition(cpu: *const Cpu, cond: u4) bool {
    return switch (cond) {
        0 => cpu.flags.overflow, // JO
        1 => !cpu.flags.overflow, // JNO
        2 => cpu.flags.carry, // JB/JC
        3 => !cpu.flags.carry, // JNB/JNC/JAE
        4 => cpu.flags.zero, // JZ/JE
        5 => !cpu.flags.zero, // JNZ/JNE
        6 => cpu.flags.carry or cpu.flags.zero, // JBE/JNA
        7 => !cpu.flags.carry and !cpu.flags.zero, // JNBE/JA
        8 => cpu.flags.sign, // JS
        9 => !cpu.flags.sign, // JNS
        10 => cpu.flags.parity, // JP/JPE
        11 => !cpu.flags.parity, // JNP/JPO
        12 => cpu.flags.sign != cpu.flags.overflow, // JL/JNGE
        13 => cpu.flags.sign == cpu.flags.overflow, // JNL/JGE
        14 => cpu.flags.zero or (cpu.flags.sign != cpu.flags.overflow), // JLE/JNG
        15 => !cpu.flags.zero and (cpu.flags.sign == cpu.flags.overflow), // JNLE/JG
    };
}

fn makeJcc(comptime cond: u4) fn (*Cpu, *Bus, u8, *const PrefixState) ExecResult {
    return struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
            const disp: i8 = @bitCast(Decoder.fetchByte(cpu, bus));
            if (evalCondition(cpu, cond)) {
                cpu.ip = cpu.ip +% @as(u16, @bitCast(@as(i16, disp)));
            }
            return .ok;
        }
    }.handler;
}

fn opLoop(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const disp: i8 = @bitCast(Decoder.fetchByte(cpu, bus));
    cpu.cx.word -%= 1;
    if (cpu.cx.word != 0) {
        cpu.ip = cpu.ip +% @as(u16, @bitCast(@as(i16, disp)));
    }
    return .ok;
}

fn opLoopz(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const disp: i8 = @bitCast(Decoder.fetchByte(cpu, bus));
    cpu.cx.word -%= 1;
    if (cpu.cx.word != 0 and cpu.flags.zero) {
        cpu.ip = cpu.ip +% @as(u16, @bitCast(@as(i16, disp)));
    }
    return .ok;
}

fn opLoopnz(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const disp: i8 = @bitCast(Decoder.fetchByte(cpu, bus));
    cpu.cx.word -%= 1;
    if (cpu.cx.word != 0 and !cpu.flags.zero) {
        cpu.ip = cpu.ip +% @as(u16, @bitCast(@as(i16, disp)));
    }
    return .ok;
}

fn opJcxz(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const disp: i8 = @bitCast(Decoder.fetchByte(cpu, bus));
    if (cpu.cx.word == 0) {
        cpu.ip = cpu.ip +% @as(u16, @bitCast(@as(i16, disp)));
    }
    return .ok;
}

fn opCallNear(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const disp: i16 = @bitCast(Decoder.fetchWord(cpu, bus));
    push16(cpu, bus, cpu.ip);
    cpu.ip = cpu.ip +% @as(u16, @bitCast(disp));
    return .ok;
}

fn opRetNear(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.ip = pop16(cpu, bus);
    return .ok;
}

fn opRetNearImm(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const imm = Decoder.fetchWord(cpu, bus);
    cpu.ip = pop16(cpu, bus);
    cpu.sp +%= imm;
    return .ok;
}

fn opCallFar(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const offset = Decoder.fetchWord(cpu, bus);
    const segment = Decoder.fetchWord(cpu, bus);
    push16(cpu, bus, cpu.cs);
    push16(cpu, bus, cpu.ip);
    cpu.cs = segment;
    cpu.ip = offset;
    return .ok;
}

fn opRetFar(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.ip = pop16(cpu, bus);
    cpu.cs = pop16(cpu, bus);
    return .ok;
}

fn opRetFarImm(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const imm = Decoder.fetchWord(cpu, bus);
    cpu.ip = pop16(cpu, bus);
    cpu.cs = pop16(cpu, bus);
    cpu.sp +%= imm;
    return .ok;
}

fn opInt(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const vector = Decoder.fetchByte(cpu, bus);
    // On WASM, intercept DOS interrupts for .COM program support.
    // On native, always go through the IVT for hardware accuracy.
    if (comptime builtin.cpu.arch == .wasm32) {
        if (vector == 0x10) return handleInt10(cpu, bus);
        if (vector == 0x16) return handleInt16(cpu, bus);
        if (vector == 0x21) return handleInt21(cpu, bus);
        if (vector == 0x20) {
            bus.halted = true;
            return .halt;
        }
    }
    doInterrupt(cpu, bus, vector);
    return .ok;
}

/// Handle DOS INT 21h services (minimal subset for .COM programs).
fn handleInt21(cpu: *Cpu, bus: *Bus) ExecResult {
    const func = cpu.ax.parts.hi; // AH = function number
    switch (func) {
        0x02 => {
            // AH=02h: Write character to stdout (DL = character)
            bus.appendOutput(cpu.dx.parts.lo);
        },
        0x09 => {
            // AH=09h: Write string to stdout (DS:DX -> '$'-terminated string)
            var offset = cpu.dx.word;
            while (true) {
                const ch = bus.read8(cpu.ds, offset);
                if (ch == '$') break;
                bus.appendOutput(ch);
                offset +%= 1;
                // Safety: stop after 4K chars to prevent infinite loops
                if (bus.output_len >= bus.output_buf.len) break;
            }
        },
        0x4C => {
            // AH=4Ch: Terminate program (AL = return code)
            bus.halted = true;
            return .halt;
        },
        else => {
            // Unhandled INT 21h function -- silently ignore for now
        },
    }
    return .ok;
}

/// Handle BIOS INT 10h video services.
fn handleInt10(cpu: *Cpu, bus: *Bus) ExecResult {
    const func = cpu.ax.parts.hi; // AH = function number
    switch (func) {
        0x00 => {
            // AH=00h: Set video mode (AL = mode)
            bus.video_mode = cpu.ax.parts.lo;
            bus.cursor_row = 0;
            bus.cursor_col = 0;
            // Clear text VRAM for text modes
            if (cpu.ax.parts.lo == 0x03 or cpu.ax.parts.lo == 0x02) {
                var i: u20 = 0;
                while (i < 4000) : (i += 2) {
                    bus.mem[Bus.TEXT_VRAM_BASE + i] = 0x20; // space
                    bus.mem[Bus.TEXT_VRAM_BASE + i + 1] = 0x07; // white on black
                }
            }
        },
        0x01 => {
            // AH=01h: Set cursor shape -- ignore, we draw a block cursor
        },
        0x02 => {
            // AH=02h: Set cursor position (DH=row, DL=col, BH=page)
            bus.cursor_row = cpu.dx.parts.hi;
            bus.cursor_col = cpu.dx.parts.lo;
            bus.active_page = cpu.bx.parts.hi;
        },
        0x03 => {
            // AH=03h: Get cursor position (BH=page)
            // Returns: DH=row, DL=col, CH=start scanline, CL=end scanline
            cpu.dx.parts.hi = bus.cursor_row;
            cpu.dx.parts.lo = bus.cursor_col;
            cpu.cx.word = 0x0607; // standard cursor shape
        },
        0x05 => {
            // AH=05h: Set active display page (AL=page)
            bus.active_page = cpu.ax.parts.lo;
        },
        0x06 => {
            // AH=06h: Scroll window up
            // AL = lines to scroll (0 = clear entire window)
            // BH = attribute for blank lines
            // CX = upper-left (CH=row, CL=col)
            // DX = lower-right (DH=row, DL=col)
            const lines = cpu.ax.parts.lo;
            const attr = cpu.bx.parts.hi;
            const top = cpu.cx.parts.hi;
            const bottom = cpu.dx.parts.hi;
            if (lines == 0) {
                // Clear the window
                var r: u8 = top;
                while (r <= bottom and r < 25) : (r += 1) {
                    var c: u8 = cpu.cx.parts.lo;
                    while (c <= cpu.dx.parts.lo and c < 80) : (c += 1) {
                        bus.writeTextCell(r, c, 0x20, attr);
                    }
                }
            } else {
                // Scroll up by 'lines' rows
                var r: u8 = top;
                while (r <= bottom and r < 25) : (r += 1) {
                    const src_row = r + lines;
                    var c: u8 = cpu.cx.parts.lo;
                    while (c <= cpu.dx.parts.lo and c < 80) : (c += 1) {
                        if (src_row <= bottom and src_row < 25) {
                            const src_off: u20 = (@as(u20, src_row) * 80 + @as(u20, c)) * 2;
                            const ch = bus.mem[Bus.TEXT_VRAM_BASE + src_off];
                            const a = bus.mem[Bus.TEXT_VRAM_BASE + src_off + 1];
                            bus.writeTextCell(r, c, ch, a);
                        } else {
                            bus.writeTextCell(r, c, 0x20, attr);
                        }
                    }
                }
            }
        },
        0x07 => {
            // AH=07h: Scroll window down -- similar to 06h but downward
            // Simplified: just clear window for now
            const attr = cpu.bx.parts.hi;
            const top = cpu.cx.parts.hi;
            const bottom = cpu.dx.parts.hi;
            var r: u8 = top;
            while (r <= bottom and r < 25) : (r += 1) {
                var c: u8 = cpu.cx.parts.lo;
                while (c <= cpu.dx.parts.lo and c < 80) : (c += 1) {
                    bus.writeTextCell(r, c, 0x20, attr);
                }
            }
        },
        0x08 => {
            // AH=08h: Read character and attribute at cursor
            const off: u20 = (@as(u20, bus.cursor_row) * 80 + @as(u20, bus.cursor_col)) * 2;
            cpu.ax.parts.lo = bus.mem[Bus.TEXT_VRAM_BASE + off]; // char
            cpu.ax.parts.hi = bus.mem[Bus.TEXT_VRAM_BASE + off + 1]; // attr
        },
        0x09 => {
            // AH=09h: Write character and attribute at cursor
            // AL=char, BH=page, BL=attr, CX=count
            const ch = cpu.ax.parts.lo;
            const attr = cpu.bx.parts.lo;
            var count = cpu.cx.word;
            var row = bus.cursor_row;
            var col = bus.cursor_col;
            while (count > 0) : (count -= 1) {
                if (row < 25 and col < 80) {
                    bus.writeTextCell(row, col, ch, attr);
                }
                col += 1;
                if (col >= 80) { col = 0; row += 1; }
            }
        },
        0x0A => {
            // AH=0Ah: Write character at cursor (attribute unchanged)
            // AL=char, CX=count
            const ch = cpu.ax.parts.lo;
            var count = cpu.cx.word;
            var row = bus.cursor_row;
            var col = bus.cursor_col;
            while (count > 0) : (count -= 1) {
                if (row < 25 and col < 80) {
                    const off: u20 = (@as(u20, row) * 80 + @as(u20, col)) * 2;
                    bus.mem[Bus.TEXT_VRAM_BASE + off] = ch;
                }
                col += 1;
                if (col >= 80) { col = 0; row += 1; }
            }
        },
        0x0E => {
            // AH=0Eh: Teletype output (write char + advance cursor)
            // AL=char, BL=foreground color (graphics mode)
            const ch = cpu.ax.parts.lo;
            switch (ch) {
                0x0D => { // CR
                    bus.cursor_col = 0;
                },
                0x0A => { // LF
                    bus.cursor_row += 1;
                    if (bus.cursor_row >= 25) {
                        bus.scrollUp();
                        bus.cursor_row = 24;
                    }
                },
                0x08 => { // Backspace
                    if (bus.cursor_col > 0) bus.cursor_col -= 1;
                },
                0x07 => { // Bell -- ignore
                },
                else => {
                    bus.writeTextCell(bus.cursor_row, bus.cursor_col, ch, 0x07);
                    bus.advanceCursor();
                },
            }
            // Also append to output buffer for the Output tab
            bus.appendOutput(ch);
        },
        0x0F => {
            // AH=0Fh: Get current video mode
            // Returns: AL=mode, AH=columns, BH=page
            cpu.ax.parts.lo = bus.video_mode;
            cpu.ax.parts.hi = 80;
            cpu.bx.parts.hi = bus.active_page;
        },
        else => {
            // Unhandled INT 10h -- silently ignore
        },
    }
    return .ok;
}

/// Handle BIOS INT 16h keyboard services.
fn handleInt16(cpu: *Cpu, bus: *Bus) ExecResult {
    const func = cpu.ax.parts.hi;
    switch (func) {
        0x00 => {
            // AH=00h: Read key (blocking).
            // If no key is available, set waiting_for_key and halt.
            // The WASM host will push a key and re-run.
            if (bus.popKey()) |key| {
                cpu.ax.parts.hi = key.scancode;
                cpu.ax.parts.lo = key.ascii;
            } else {
                // No key available: rewind IP to re-execute this INT 16h
                // when the host resumes after pushing a key.
                cpu.ip -%= 2; // back over CD 16
                bus.waiting_for_key = true;
                return .halt;
            }
        },
        0x01 => {
            // AH=01h: Check key buffer (non-blocking).
            // ZF=1 if no key, ZF=0 if key ready. Key stays in buffer.
            if (bus.peekKey()) |key| {
                cpu.flags.zero = false;
                cpu.ax.parts.hi = key.scancode;
                cpu.ax.parts.lo = key.ascii;
            } else {
                cpu.flags.zero = true;
            }
        },
        0x02 => {
            // AH=02h: Get shift key status.
            // Returns AL with shift flags -- return 0 (no modifiers).
            cpu.ax.parts.lo = 0;
        },
        else => {
            // Unhandled INT 16h -- silently ignore
        },
    }
    return .ok;
}

fn opInt3(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    doInterrupt(cpu, bus, 3);
    return .ok;
}

fn opInto(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    if (cpu.flags.overflow) {
        doInterrupt(cpu, bus, 4);
    }
    return .ok;
}

fn opIret(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.ip = pop16(cpu, bus);
    cpu.cs = pop16(cpu, bus);
    cpu.flags = Cpu.Flags.unpack(pop16(cpu, bus));
    return .ok;
}

fn doInterrupt(cpu: *Cpu, bus: *Bus, vector: u8) void {
    push16(cpu, bus, cpu.flags.pack());
    cpu.flags.interrupt = false;
    cpu.flags.trap = false;
    push16(cpu, bus, cpu.cs);
    push16(cpu, bus, cpu.ip);
    // Read IVT entry: 4 bytes at vector * 4
    const ivt_addr: u20 = @as(u20, vector) * 4;
    cpu.ip = bus.readPhys16(ivt_addr);
    cpu.cs = bus.readPhys16(ivt_addr +% 2);
}

// FF group: INC/DEC/CALL near indirect/JMP near indirect/CALL far indirect/JMP far indirect/PUSH
fn opGrpFF(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    const modrm_byte = Decoder.fetchByte(cpu, bus);
    const modrm = Decoder.decodeModRM(modrm_byte);
    const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);

    switch (modrm.reg) {
        0 => { // INC r/m16
            const val = readEA(cpu, bus, ea, .word);
            writeEA(cpu, bus, ea, .word, flags_mod.inc16(&cpu.flags, val));
        },
        1 => { // DEC r/m16
            const val = readEA(cpu, bus, ea, .word);
            writeEA(cpu, bus, ea, .word, flags_mod.dec16(&cpu.flags, val));
        },
        2 => { // CALL near indirect
            const target = readEA(cpu, bus, ea, .word);
            push16(cpu, bus, cpu.ip);
            cpu.ip = target;
        },
        3 => { // CALL far indirect
            switch (ea) {
                .memory => |m| {
                    const new_ip = bus.read16(m.segment, m.offset);
                    const new_cs = bus.read16(m.segment, m.offset +% 2);
                    push16(cpu, bus, cpu.cs);
                    push16(cpu, bus, cpu.ip);
                    cpu.ip = new_ip;
                    cpu.cs = new_cs;
                },
                .register => return .unimplemented,
            }
        },
        4 => { // JMP near indirect
            cpu.ip = readEA(cpu, bus, ea, .word);
        },
        5 => { // JMP far indirect
            switch (ea) {
                .memory => |m| {
                    cpu.ip = bus.read16(m.segment, m.offset);
                    cpu.cs = bus.read16(m.segment, m.offset +% 2);
                },
                .register => return .unimplemented,
            }
        },
        6 => { // PUSH r/m16
            // 8086 PUSH SP quirk: if source is SP register, push after decrement
            switch (ea) {
                .register => |r| {
                    if (r == 4) { // SP
                        cpu.sp -%= 2;
                        bus.write16(cpu.ss, cpu.sp, cpu.sp);
                    } else {
                        push16(cpu, bus, cpu.getReg16(r));
                    }
                },
                .memory => |m| {
                    const val = bus.read16(m.segment, m.offset);
                    push16(cpu, bus, val);
                },
            }
        },
        7 => return .unimplemented,
    }
    return .ok;
}

// --- Data Movement (Phase 5) ---

fn opXchgRM(comptime size: OpSize) fn (*Cpu, *Bus, u8, *const PrefixState) ExecResult {
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

            writeEA(cpu, bus, ea, size, reg_val);
            switch (size) {
                .byte => cpu.setReg8(modrm.reg, @truncate(rm_val)),
                .word => cpu.setReg16(modrm.reg, rm_val),
            }

            return .ok;
        }
    }.handler;
}

fn opLea(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    const modrm_byte = Decoder.fetchByte(cpu, bus);
    const modrm = Decoder.decodeModRM(modrm_byte);
    const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);
    switch (ea) {
        .memory => |m| cpu.setReg16(modrm.reg, m.offset),
        .register => {}, // LEA with register source is undefined behavior
    }
    return .ok;
}

fn opLds(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    const modrm_byte = Decoder.fetchByte(cpu, bus);
    const modrm = Decoder.decodeModRM(modrm_byte);
    const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);
    switch (ea) {
        .memory => |m| {
            cpu.setReg16(modrm.reg, bus.read16(m.segment, m.offset));
            cpu.ds = bus.read16(m.segment, m.offset +% 2);
        },
        .register => {},
    }
    return .ok;
}

fn opLes(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    const modrm_byte = Decoder.fetchByte(cpu, bus);
    const modrm = Decoder.decodeModRM(modrm_byte);
    const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);
    switch (ea) {
        .memory => |m| {
            cpu.setReg16(modrm.reg, bus.read16(m.segment, m.offset));
            cpu.es = bus.read16(m.segment, m.offset +% 2);
        },
        .register => {},
    }
    return .ok;
}

fn opLahf(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.ax.parts.hi = @truncate(cpu.flags.pack());
    return .ok;
}

fn opSahf(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    // SAHF loads SF, ZF, AF, PF, CF from AH
    const ah = cpu.ax.parts.hi;
    cpu.flags.sign = (ah & 0x80) != 0;
    cpu.flags.zero = (ah & 0x40) != 0;
    cpu.flags.aux_carry = (ah & 0x10) != 0;
    cpu.flags.parity = (ah & 0x04) != 0;
    cpu.flags.carry = (ah & 0x01) != 0;
    return .ok;
}

fn opPushf(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    push16(cpu, bus, cpu.flags.pack());
    return .ok;
}

fn opPopf(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.flags = Cpu.Flags.unpack(pop16(cpu, bus));
    return .ok;
}

fn opCbw(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const al: i8 = @bitCast(cpu.ax.parts.lo);
    cpu.ax.word = @bitCast(@as(i16, al));
    return .ok;
}

fn opCwd(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    if (cpu.ax.word & 0x8000 != 0) {
        cpu.dx.word = 0xFFFF;
    } else {
        cpu.dx.word = 0x0000;
    }
    return .ok;
}

fn opXlat(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    const seg = prefix.seg_override orelse cpu.ds;
    const offset = cpu.bx.word +% @as(u16, cpu.ax.parts.lo);
    cpu.ax.parts.lo = bus.read8(seg, offset);
    return .ok;
}

// --- Shifts and Rotates (Phase 6) ---

const ShiftCount = enum { one, cl };

fn opGrpShift(comptime size: OpSize, comptime count_src: ShiftCount) fn (*Cpu, *Bus, u8, *const PrefixState) ExecResult {
    return struct {
        fn handler(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
            const modrm_byte = Decoder.fetchByte(cpu, bus);
            const modrm = Decoder.decodeModRM(modrm_byte);
            const ea = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);
            var val: u16 = readEA(cpu, bus, ea, size);

            const count: u8 = switch (count_src) {
                .one => 1,
                .cl => cpu.cx.parts.lo,
            };

            var i: u8 = 0;
            while (i < count) : (i += 1) {
                val = doShiftOne(cpu, modrm.reg, val, size);
            }

            // Overflow flag is only defined for single-bit shifts
            if (count == 1) {
                switch (modrm.reg) {
                    0 => { // ROL
                        cpu.flags.overflow = switch (size) {
                            .byte => (val & 0x80 != 0) != cpu.flags.carry,
                            .word => (val & 0x8000 != 0) != cpu.flags.carry,
                        };
                    },
                    1 => { // ROR
                        switch (size) {
                            .byte => cpu.flags.overflow = ((val >> 7) & 1) != ((val >> 6) & 1),
                            .word => cpu.flags.overflow = ((val >> 15) & 1) != ((val >> 14) & 1),
                        }
                    },
                    2 => { // RCL
                        cpu.flags.overflow = switch (size) {
                            .byte => (val & 0x80 != 0) != cpu.flags.carry,
                            .word => (val & 0x8000 != 0) != cpu.flags.carry,
                        };
                    },
                    3 => { // RCR
                        switch (size) {
                            .byte => cpu.flags.overflow = ((val >> 7) & 1) != ((val >> 6) & 1),
                            .word => cpu.flags.overflow = ((val >> 15) & 1) != ((val >> 14) & 1),
                        }
                    },
                    4, 6 => { // SHL/SAL
                        cpu.flags.overflow = switch (size) {
                            .byte => (val & 0x80 != 0) != cpu.flags.carry,
                            .word => (val & 0x8000 != 0) != cpu.flags.carry,
                        };
                    },
                    5 => { // SHR
                        switch (size) {
                            .byte => cpu.flags.overflow = (val & 0x80) != 0,
                            .word => cpu.flags.overflow = (val & 0x8000) != 0,
                        }
                        // For SHR by 1, OF = MSB of original value
                        // But we already shifted, so check bit below MSB... actually
                        // OF is set to MSB of the original operand
                        // We need the pre-shift value, but we computed post-shift.
                        // For count=1: original MSB = (result << 1 | CF) MSB
                        // Simpler: OF = result MSB XOR (result bit below MSB) is wrong.
                        // Actually for SHR by 1: OF = MSB of original = carry_out of shift into MSB
                        // Since we shift right: OF = bit that was in MSB = (result's MSB-1 bit? No)
                        // On 8086: SHR by 1 sets OF = high bit of original operand
                        // post-shift MSB is always 0, so OF = CF for the second-to-last... no.
                        // SHR: OF = MSB of original. After shift right by 1:
                        // result = original >> 1, CF = original bit 0
                        // original MSB = result's (MSB-1) bit shifted up... no, result bit (n-1) = original bit n
                        // So original MSB = ... it's gone if 0. Actually:
                        // For byte: original bit 7 = 0 if result bit 7 is 0 AND result bit 6 is 0
                        // Wait: result = original >> 1. So result[6] = original[7].
                        // OF = original[7] = result[6]
                        cpu.flags.overflow = switch (size) {
                            .byte => (val >> 6) & 1 != 0,
                            .word => (val >> 14) & 1 != 0,
                        };
                    },
                    7 => { // SAR
                        cpu.flags.overflow = false; // always 0 for SAR by 1
                    },
                }
            }

            if (count > 0) {
                writeEA(cpu, bus, ea, size, val);
            }

            return .ok;
        }
    }.handler;
}

/// Perform one shift/rotate operation, updating CF and (for shifts) SZP flags.
fn doShiftOne(cpu: *Cpu, op: u3, val: u16, comptime size: OpSize) u16 {
    return switch (op) {
        0 => blk: { // ROL
            const top_bit: u1 = switch (size) {
                .byte => @truncate((val >> 7) & 1),
                .word => @truncate((val >> 15) & 1),
            };
            const r = switch (size) {
                .byte => (@as(u16, @as(u8, @truncate(val))) << 1) | top_bit,
                .word => (val << 1) | top_bit,
            };
            cpu.flags.carry = top_bit != 0;
            break :blk r;
        },
        1 => blk: { // ROR
            const bottom_bit: u1 = @truncate(val & 1);
            const r = switch (size) {
                .byte => (@as(u16, bottom_bit) << 7) | (@as(u8, @truncate(val)) >> 1),
                .word => (@as(u16, bottom_bit) << 15) | (val >> 1),
            };
            cpu.flags.carry = bottom_bit != 0;
            break :blk r;
        },
        2 => blk: { // RCL
            const old_cf: u1 = if (cpu.flags.carry) 1 else 0;
            const top_bit = switch (size) {
                .byte => (val >> 7) & 1,
                .word => (val >> 15) & 1,
            };
            cpu.flags.carry = top_bit != 0;
            const r = switch (size) {
                .byte => (@as(u16, @as(u8, @truncate(val))) << 1) | old_cf,
                .word => (val << 1) | old_cf,
            };
            break :blk r;
        },
        3 => blk: { // RCR
            const old_cf: u1 = if (cpu.flags.carry) 1 else 0;
            const bottom_bit: u1 = @truncate(val & 1);
            cpu.flags.carry = bottom_bit != 0;
            const r = switch (size) {
                .byte => (@as(u16, old_cf) << 7) | (@as(u8, @truncate(val)) >> 1),
                .word => (@as(u16, old_cf) << 15) | (val >> 1),
            };
            break :blk r;
        },
        4, 6 => blk: { // SHL/SAL
            const top_bit = switch (size) {
                .byte => (val >> 7) & 1,
                .word => (val >> 15) & 1,
            };
            cpu.flags.carry = top_bit != 0;
            const r = switch (size) {
                .byte => @as(u16, @as(u8, @truncate(val))) << 1,
                .word => val << 1,
            };
            switch (size) {
                .byte => flags_mod.setSzp8(&cpu.flags, @truncate(r)),
                .word => flags_mod.setSzp16(&cpu.flags, r),
            }
            cpu.flags.aux_carry = false; // undefined, clear for consistency
            break :blk r;
        },
        5 => blk: { // SHR
            const bottom_bit: u1 = @truncate(val & 1);
            cpu.flags.carry = bottom_bit != 0;
            const r = switch (size) {
                .byte => @as(u16, @as(u8, @truncate(val)) >> 1),
                .word => val >> 1,
            };
            switch (size) {
                .byte => flags_mod.setSzp8(&cpu.flags, @truncate(r)),
                .word => flags_mod.setSzp16(&cpu.flags, r),
            }
            cpu.flags.aux_carry = false;
            break :blk r;
        },
        7 => blk: { // SAR
            const bottom_bit: u1 = @truncate(val & 1);
            cpu.flags.carry = bottom_bit != 0;
            const r: u16 = switch (size) {
                .byte => @bitCast(@as(i16, @as(i8, @bitCast(@as(u8, @truncate(val)))) >> 1)),
                .word => @bitCast(@as(i16, @bitCast(val)) >> 1),
            };
            switch (size) {
                .byte => flags_mod.setSzp8(&cpu.flags, @truncate(r)),
                .word => flags_mod.setSzp16(&cpu.flags, r),
            }
            cpu.flags.aux_carry = false;
            break :blk r;
        },
    };
}

// --- BCD Instructions ---

fn opDaa(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const old_al = cpu.ax.parts.lo;
    const old_cf = cpu.flags.carry;

    if ((cpu.ax.parts.lo & 0x0F) > 9 or cpu.flags.aux_carry) {
        cpu.ax.parts.lo +%= 6;
        cpu.flags.aux_carry = true;
    } else {
        cpu.flags.aux_carry = false;
    }

    if (old_al > 0x99 or old_cf) {
        cpu.ax.parts.lo +%= 0x60;
        cpu.flags.carry = true;
    } else {
        cpu.flags.carry = false;
    }

    flags_mod.setSzp8(&cpu.flags, cpu.ax.parts.lo);
    return .ok;
}

fn opDas(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const old_al = cpu.ax.parts.lo;
    const old_cf = cpu.flags.carry;

    if ((cpu.ax.parts.lo & 0x0F) > 9 or cpu.flags.aux_carry) {
        cpu.ax.parts.lo -%= 6;
        cpu.flags.aux_carry = true;
    } else {
        cpu.flags.aux_carry = false;
    }

    if (old_al > 0x99 or old_cf) {
        cpu.ax.parts.lo -%= 0x60;
        cpu.flags.carry = true;
    } else {
        cpu.flags.carry = false;
    }

    flags_mod.setSzp8(&cpu.flags, cpu.ax.parts.lo);
    return .ok;
}

fn opAaa(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    if ((cpu.ax.parts.lo & 0x0F) > 9 or cpu.flags.aux_carry) {
        cpu.ax.parts.lo +%= 6;
        cpu.ax.parts.hi +%= 1;
        cpu.flags.aux_carry = true;
        cpu.flags.carry = true;
    } else {
        cpu.flags.aux_carry = false;
        cpu.flags.carry = false;
    }
    cpu.ax.parts.lo &= 0x0F;
    flags_mod.setSzp8(&cpu.flags, cpu.ax.parts.lo);
    return .ok;
}

fn opAas(cpu: *Cpu, _: *Bus, _: u8, _: *const PrefixState) ExecResult {
    if ((cpu.ax.parts.lo & 0x0F) > 9 or cpu.flags.aux_carry) {
        cpu.ax.parts.lo -%= 6;
        cpu.ax.parts.hi -%= 1;
        cpu.flags.aux_carry = true;
        cpu.flags.carry = true;
    } else {
        cpu.flags.aux_carry = false;
        cpu.flags.carry = false;
    }
    cpu.ax.parts.lo &= 0x0F;
    flags_mod.setSzp8(&cpu.flags, cpu.ax.parts.lo);
    return .ok;
}

fn opAam(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const base = Decoder.fetchByte(cpu, bus);
    if (base == 0) {
        doInterrupt(cpu, bus, 0);
        return .ok;
    }
    const al = cpu.ax.parts.lo;
    cpu.ax.parts.hi = al / base;
    cpu.ax.parts.lo = al % base;
    flags_mod.setSzp8(&cpu.flags, cpu.ax.parts.lo);
    cpu.flags.carry = false;
    cpu.flags.overflow = false;
    cpu.flags.aux_carry = false;
    return .ok;
}

fn opAad(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const base = Decoder.fetchByte(cpu, bus);
    const al = cpu.ax.parts.lo;
    const product: u8 = cpu.ax.parts.hi *% base;
    // AAD performs an 8-bit add (AL + AH*base) with full flag effects
    cpu.ax.parts.lo = flags_mod.add8(&cpu.flags, al, product, 0);
    cpu.ax.parts.hi = 0;
    return .ok;
}

// --- String Operations ---

fn stringSegSrc(cpu: *const Cpu, prefix: *const PrefixState) u16 {
    return prefix.seg_override orelse cpu.ds;
}

fn advanceSI(cpu: *Cpu, comptime size: OpSize) void {
    if (cpu.flags.direction) {
        cpu.si -%= switch (size) { .byte => 1, .word => 2 };
    } else {
        cpu.si +%= switch (size) { .byte => 1, .word => 2 };
    }
}

fn advanceDI(cpu: *Cpu, comptime size: OpSize) void {
    if (cpu.flags.direction) {
        cpu.di -%= switch (size) { .byte => 1, .word => 2 };
    } else {
        cpu.di +%= switch (size) { .byte => 1, .word => 2 };
    }
}

fn opMovsb(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    if (prefix.rep_prefix != .none) {
        while (cpu.cx.word != 0) {
            const val = bus.read8(stringSegSrc(cpu, prefix), cpu.si);
            bus.write8(cpu.es, cpu.di, val);
            advanceSI(cpu, .byte);
            advanceDI(cpu, .byte);
            cpu.cx.word -%= 1;
        }
    } else {
        const val = bus.read8(stringSegSrc(cpu, prefix), cpu.si);
        bus.write8(cpu.es, cpu.di, val);
        advanceSI(cpu, .byte);
        advanceDI(cpu, .byte);
    }
    return .ok;
}

fn opMovsw(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    if (prefix.rep_prefix != .none) {
        while (cpu.cx.word != 0) {
            const val = bus.read16(stringSegSrc(cpu, prefix), cpu.si);
            bus.write16(cpu.es, cpu.di, val);
            advanceSI(cpu, .word);
            advanceDI(cpu, .word);
            cpu.cx.word -%= 1;
        }
    } else {
        const val = bus.read16(stringSegSrc(cpu, prefix), cpu.si);
        bus.write16(cpu.es, cpu.di, val);
        advanceSI(cpu, .word);
        advanceDI(cpu, .word);
    }
    return .ok;
}

fn opCmpsb(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    if (prefix.rep_prefix == .rep or prefix.rep_prefix == .repnz) {
        while (cpu.cx.word != 0) {
            const a = bus.read8(stringSegSrc(cpu, prefix), cpu.si);
            const b = bus.read8(cpu.es, cpu.di);
            _ = flags_mod.sub8(&cpu.flags, a, b, 0);
            advanceSI(cpu, .byte);
            advanceDI(cpu, .byte);
            cpu.cx.word -%= 1;
            if (prefix.rep_prefix == .rep and !cpu.flags.zero) break;
            if (prefix.rep_prefix == .repnz and cpu.flags.zero) break;
        }
    } else {
        const a = bus.read8(stringSegSrc(cpu, prefix), cpu.si);
        const b = bus.read8(cpu.es, cpu.di);
        _ = flags_mod.sub8(&cpu.flags, a, b, 0);
        advanceSI(cpu, .byte);
        advanceDI(cpu, .byte);
    }
    return .ok;
}

fn opCmpsw(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    if (prefix.rep_prefix == .rep or prefix.rep_prefix == .repnz) {
        while (cpu.cx.word != 0) {
            const a = bus.read16(stringSegSrc(cpu, prefix), cpu.si);
            const b = bus.read16(cpu.es, cpu.di);
            _ = flags_mod.sub16(&cpu.flags, a, b, 0);
            advanceSI(cpu, .word);
            advanceDI(cpu, .word);
            cpu.cx.word -%= 1;
            if (prefix.rep_prefix == .rep and !cpu.flags.zero) break;
            if (prefix.rep_prefix == .repnz and cpu.flags.zero) break;
        }
    } else {
        const a = bus.read16(stringSegSrc(cpu, prefix), cpu.si);
        const b = bus.read16(cpu.es, cpu.di);
        _ = flags_mod.sub16(&cpu.flags, a, b, 0);
        advanceSI(cpu, .word);
        advanceDI(cpu, .word);
    }
    return .ok;
}

fn opStosb(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    if (prefix.rep_prefix != .none) {
        while (cpu.cx.word != 0) {
            bus.write8(cpu.es, cpu.di, cpu.ax.parts.lo);
            advanceDI(cpu, .byte);
            cpu.cx.word -%= 1;
        }
    } else {
        bus.write8(cpu.es, cpu.di, cpu.ax.parts.lo);
        advanceDI(cpu, .byte);
    }
    return .ok;
}

fn opStosw(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    if (prefix.rep_prefix != .none) {
        while (cpu.cx.word != 0) {
            bus.write16(cpu.es, cpu.di, cpu.ax.word);
            advanceDI(cpu, .word);
            cpu.cx.word -%= 1;
        }
    } else {
        bus.write16(cpu.es, cpu.di, cpu.ax.word);
        advanceDI(cpu, .word);
    }
    return .ok;
}

fn opLodsb(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    if (prefix.rep_prefix != .none) {
        while (cpu.cx.word != 0) {
            cpu.ax.parts.lo = bus.read8(stringSegSrc(cpu, prefix), cpu.si);
            advanceSI(cpu, .byte);
            cpu.cx.word -%= 1;
        }
    } else {
        cpu.ax.parts.lo = bus.read8(stringSegSrc(cpu, prefix), cpu.si);
        advanceSI(cpu, .byte);
    }
    return .ok;
}

fn opLodsw(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    if (prefix.rep_prefix != .none) {
        while (cpu.cx.word != 0) {
            cpu.ax.word = bus.read16(stringSegSrc(cpu, prefix), cpu.si);
            advanceSI(cpu, .word);
            cpu.cx.word -%= 1;
        }
    } else {
        cpu.ax.word = bus.read16(stringSegSrc(cpu, prefix), cpu.si);
        advanceSI(cpu, .word);
    }
    return .ok;
}

fn opScasb(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    if (prefix.rep_prefix == .rep or prefix.rep_prefix == .repnz) {
        while (cpu.cx.word != 0) {
            const val = bus.read8(cpu.es, cpu.di);
            _ = flags_mod.sub8(&cpu.flags, cpu.ax.parts.lo, val, 0);
            advanceDI(cpu, .byte);
            cpu.cx.word -%= 1;
            if (prefix.rep_prefix == .rep and !cpu.flags.zero) break;
            if (prefix.rep_prefix == .repnz and cpu.flags.zero) break;
        }
    } else {
        const val = bus.read8(cpu.es, cpu.di);
        _ = flags_mod.sub8(&cpu.flags, cpu.ax.parts.lo, val, 0);
        advanceDI(cpu, .byte);
    }
    return .ok;
}

fn opScasw(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    if (prefix.rep_prefix == .rep or prefix.rep_prefix == .repnz) {
        while (cpu.cx.word != 0) {
            const val = bus.read16(cpu.es, cpu.di);
            _ = flags_mod.sub16(&cpu.flags, cpu.ax.word, val, 0);
            advanceDI(cpu, .word);
            cpu.cx.word -%= 1;
            if (prefix.rep_prefix == .rep and !cpu.flags.zero) break;
            if (prefix.rep_prefix == .repnz and cpu.flags.zero) break;
        }
    } else {
        const val = bus.read16(cpu.es, cpu.di);
        _ = flags_mod.sub16(&cpu.flags, cpu.ax.word, val, 0);
        advanceDI(cpu, .word);
    }
    return .ok;
}

// --- I/O ---

fn opInAlImm(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const port = Decoder.fetchByte(cpu, bus);
    cpu.ax.parts.lo = bus.inPort8(port);
    return .ok;
}

fn opInAxImm(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const port = Decoder.fetchByte(cpu, bus);
    cpu.ax.parts.lo = bus.inPort8(port);
    cpu.ax.parts.hi = bus.inPort8(port +% 1);
    return .ok;
}

fn opOutImmAl(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const port = Decoder.fetchByte(cpu, bus);
    bus.outPort8(port, cpu.ax.parts.lo);
    return .ok;
}

fn opOutImmAx(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    const port = Decoder.fetchByte(cpu, bus);
    bus.outPort8(port, cpu.ax.parts.lo);
    bus.outPort8(port +% 1, cpu.ax.parts.hi);
    return .ok;
}

fn opInAlDx(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.ax.parts.lo = bus.inPort8(cpu.dx.word);
    return .ok;
}

fn opInAxDx(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    cpu.ax.parts.lo = bus.inPort8(cpu.dx.word);
    cpu.ax.parts.hi = bus.inPort8(cpu.dx.word +% 1);
    return .ok;
}

fn opOutDxAl(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    bus.outPort8(cpu.dx.word, cpu.ax.parts.lo);
    return .ok;
}

fn opOutDxAx(cpu: *Cpu, bus: *Bus, _: u8, _: *const PrefixState) ExecResult {
    bus.outPort8(cpu.dx.word, cpu.ax.parts.lo);
    bus.outPort8(cpu.dx.word +% 1, cpu.ax.parts.hi);
    return .ok;
}

// ESC (FPU escape) -- consume ModR/M and ignore
fn opEsc(cpu: *Cpu, bus: *Bus, _: u8, prefix: *const PrefixState) ExecResult {
    const modrm_byte = Decoder.fetchByte(cpu, bus);
    const modrm = Decoder.decodeModRM(modrm_byte);
    // Consume any displacement bytes
    _ = Decoder.resolveModRM(cpu, bus, modrm, prefix.seg_override);
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
