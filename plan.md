# 8086 Emulator in Zig

A cycle-aware Intel 8086 CPU emulator, validated against hardware-captured test suites.

## Goals

- Correctly execute all 8086 instructions
- Pass the SingleStepTests/8086 hardware-captured test suite
- Load and run DOS .COM binaries
- Clean, readable Zig -- no shortcuts, no magic numbers

## Non-Goals (for now)

- Full PC emulation (BIOS, interrupts, peripherals, display)
- Cycle-exact bus timing
- 80186/80286 extensions

## Architecture

```
src/
  main.zig            CLI entry point, file loading, run loop
  cpu.zig             CPU state: registers, flags, segment registers
  bus.zig             1MB memory bus, I/O port stubs
  decode.zig          Instruction decoder: opcode, ModR/M, SIB, displacement, immediate
  execute.zig         Instruction execution, flag computation
  opcodes.zig         Opcode lookup table (comptime-generated)
  modrm.zig           ModR/M + displacement decoding, effective address calc
  flags.zig           Flag helpers: parity, overflow, aux carry, etc.
  test_runner.zig     JSON test suite loader and validator
build.zig
tests/               SingleStepTests JSON files (gitignored, downloaded separately)
```

### Key Design Decisions

- **Register file** uses a packed union so AX/AH/AL share storage naturally.
- **Opcode dispatch** via a comptime 256-entry function pointer table. No giant switch.
- **Memory** is a flat `[1048576]u8` array. Segment:offset resolved at the bus level.
- **Flags** stored individually as bools, packed into the FLAGS register on demand.
- **Test-first**: the JSON test runner is built early so every new opcode is validated immediately.

## Phases

### Phase 1: Foundation

1. `build.zig` -- project setup, test step
2. `cpu.zig` -- register file with hi/lo byte access, FLAGS register
3. `bus.zig` -- 1MB memory, read/write u8/u16 with segment:offset addressing
4. `decode.zig` -- fetch bytes from CS:IP, decode ModR/M byte
5. Smoke test: manually set memory, read it back

### Phase 2: Test Infrastructure

1. Download SingleStepTests/8086 JSON files
2. `test_runner.zig` -- parse JSON test cases (initial state, expected final state)
3. Wire up: load initial state into CPU + memory, execute one instruction, compare
4. CI-friendly: `zig build test` runs the suite

### Phase 3: Core Instructions (Group 1)

These cover the most common opcodes and unlock simple programs:

- MOV (reg/reg, reg/mem, mem/reg, imm/reg, imm/mem, segment)
- ADD, ADC, SUB, SBB, CMP (with all ModR/M variants + immediate)
- INC, DEC (register and memory)
- AND, OR, XOR, NOT, TEST
- NOP
- HLT

### Phase 4: Control Flow

- JMP (short, near, far, indirect)
- Jcc (JZ, JNZ, JC, JNC, JS, JNS, JO, JNO, JP, JNP, JL, JLE, JG, JGE, JB, JBE, JA, JAE)
- LOOP, LOOPZ, LOOPNZ
- CALL (near, far), RET (near, far)
- INT, INTO, IRET

### Phase 5: Data Movement & Stack

- PUSH, POP (register, segment, memory)
- XCHG
- LEA, LDS, LES
- LAHF, SAHF, PUSHF, POPF
- CBW, CWD
- XLAT

### Phase 6: Arithmetic & Shifts

- MUL, IMUL, DIV, IDIV
- NEG
- SHL/SAL, SHR, SAR, ROL, ROR, RCL, RCR (by 1 and by CL)
- DAA, DAS, AAA, AAS, AAM, AAD

### Phase 7: String Operations

- MOVSB, MOVSW
- CMPSB, CMPSW
- SCASB, SCASW
- LODSB, LODSW
- STOSB, STOSW
- REP, REPZ, REPNZ prefixes

### Phase 8: Segment & Misc

- Segment override prefixes (CS:, DS:, ES:, SS:)
- LOCK prefix (acknowledge, no-op for emulation)
- CLC, STC, CMC, CLD, STD, CLI, STI
- IN, OUT (stub I/O ports)
- ESC (FPU escape -- no-op)
- WAIT

### Phase 9: .COM Loader

- Load .COM file at 0000:0100
- Set up PSP (Program Segment Prefix) at offset 0x00
- Set SS:SP to end of segment
- Set CS=DS=ES=SS to the load segment
- Basic INT 21h stubs (print char, print string, exit)

### Phase 10: Polish

- Disassembler output (print each instruction as it executes)
- Step-through debugger mode (single-step, breakpoints, register dump)
- Memory dump viewer
- Performance: measure MIPS on a benchmark .COM

## References

- [SingleStepTests/8086](https://github.com/SingleStepTests/8086) -- hardware-captured test suite
- [8086tiny](https://github.com/adriancable/8086tiny) -- reference emulator in C
- [Intel 8086 Family User's Manual](https://edge.edx.org/c4x/BITSPilani/EEE231/asset/8086_family_Users_Manual_1_.pdf) -- official reference
- [8086 Opcode Map](http://www.mlsite.net/8086/) -- visual opcode table
- [VOGONS 8086 test thread](https://www.vogons.org/viewtopic.php?t=73677) -- community resources
