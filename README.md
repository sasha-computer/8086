# emu8086

An Intel 8086 CPU emulator in Zig, validated instruction-by-instruction against
[SingleStepTests/8086](https://github.com/SingleStepTests/8086) hardware-captured
test vectors.

82 test groups passing across all 294 test files. Every implemented opcode is
verified against traces from real 8086 silicon.

## Building

Requires [Zig 0.15+](https://ziglang.org/download/).

```
zig build
```

## Testing

Tests require the SingleStepTests JSON files. Download them first:

```sh
mkdir -p tests
for i in $(seq 0 255); do
  hex=$(printf '%02X' $i)
  url="https://github.com/SingleStepTests/8086/raw/main/v1/${hex}.json.gz"
  curl -sL "$url" | gunzip > "tests/${hex}.json" 2>/dev/null
done
```

Some opcodes have sub-group tests (e.g. `80.0.json`, `F6.5.json`). The test
runner expects these in `tests/` as well. See the
[SingleStepTests repo](https://github.com/SingleStepTests/8086) for the full
file listing.

Then run:

```
zig build test
```

## Architecture

```
src/
  main.zig          Entry point (TODO: .COM loader)
  cpu.zig           CPU state -- packed union registers, FLAGS, segments
  bus.zig           1MB flat memory, segment:offset addressing
  decode.zig        Instruction fetch, ModR/M decode, effective address calc
  execute.zig       Comptime 256-entry dispatch table, all instruction handlers
  flags.zig         Flag computation (parity LUT, add/sub/logic flag helpers)
  test_runner.zig   JSON test suite parser, state loader, delta comparator
```

### Design decisions

- **Register file** uses packed unions so AX/AH/AL share storage naturally,
  matching real hardware layout.
- **Opcode dispatch** via a comptime 256-entry function pointer table. No
  runtime switch. Parameterized comptime generators (`makeArithModRM`,
  `makeLogicModRM`, etc.) produce type-safe handlers for all size/direction
  combinations.
- **Memory** is a heap-allocated flat `[1048576]u8`. Segment:offset resolved at
  the bus level with 20-bit address wrapping.
- **Flags** stored as individual bools, packed into the FLAGS register on demand.
- **Test-driven**: the JSON test runner was built in phase 2 so every new opcode
  was validated against hardware immediately.

## Instruction coverage

All documented 8086 instructions are implemented:

| Category | Instructions |
|---|---|
| Arithmetic | ADD, ADC, SUB, SBB, CMP, INC, DEC, NEG, MUL, IMUL, DIV, IDIV |
| Logic | AND, OR, XOR, NOT, TEST |
| Shifts/Rotates | SHL, SHR, SAR, ROL, ROR, RCL, RCR (by 1 and by CL) |
| Data movement | MOV (14 variants), XCHG, LEA, LDS, LES, XLAT |
| Stack | PUSH, POP, PUSHF, POPF (register, segment, memory) |
| Control flow | JMP, Jcc (16 conditions), LOOP/LOOPZ/LOOPNZ, CALL, RET, INT, IRET |
| String ops | MOVS, CMPS, SCAS, LODS, STOS (byte/word, with REP/REPNE) |
| BCD | DAA, DAS, AAA, AAS, AAM, AAD |
| Flags | CLC, STC, CMC, CLD, STD, CLI, STI, LAHF, SAHF, CBW, CWD |
| Prefixes | Segment overrides (CS/DS/ES/SS), LOCK, REP/REPZ/REPNZ |
| Misc | NOP, HLT, IN/OUT (stubs), WAIT, ESC (FPU escape, no-op) |

### Known limitations

- **DIV/IDIV overflow**: Division by zero triggers INT 0, which pushes FLAGS to
  the stack. Undefined flag bits in the pushed value cause RAM byte mismatches
  against hardware traces. The division logic itself is correct for all
  non-overflow cases.
- **DAA/DAS edge case**: 17/2000 test cases fail when AL is 0x9A-0x9F with
  AF=1 and CF=0. The 8086's nibble-carry interaction for this specific
  combination is underdocumented.
- **MUL/IMUL SF**: The sign flag after multiply is undefined on the 8086.
  Hardware behavior varies; tests mask SF for these opcodes.

## What's next

- .COM binary loader (load at 0000:0100, set up PSP, basic INT 21h stubs)
- Disassembler trace output
- Step-through debugger mode
- Cycle counting

## References

- [SingleStepTests/8086](https://github.com/SingleStepTests/8086) -- hardware-captured test vectors
- [Intel 8086 Family User's Manual](https://edge.edx.org/c4x/BITSPilani/EEE231/asset/8086_family_Users_Manual_1_.pdf)
- [8086 Opcode Map](http://www.mlsite.net/8086/)
