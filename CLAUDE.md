# CLAUDE.md

## Project

Intel 8086 CPU emulator in Zig 0.15. Validated against SingleStepTests/8086
hardware-captured test vectors (294 JSON files, 82 test groups).

## Build & test

```
zig build          # build the emulator
zig build test     # run all tests (requires test JSON files in tests/)
```

Tests take a while -- they parse ~700MB of JSON and run hundreds of thousands of
individual test cases against the emulator.

## Source layout

| File | Purpose |
|---|---|
| `src/cpu.zig` | CPU state: packed union registers (AX/AH/AL share storage), FLAGS as bools, segments |
| `src/bus.zig` | 1MB flat memory, segment:offset with 20-bit wrap, little-endian u8/u16 read/write |
| `src/decode.zig` | Instruction fetch from CS:IP, ModR/M decode, effective address resolution |
| `src/execute.zig` | Comptime 256-entry dispatch table, all instruction handlers, prefix loop |
| `src/flags.zig` | Flag computation: comptime parity LUT, add/sub/inc/dec/logic flag helpers |
| `src/test_runner.zig` | JSON parser for SingleStepTests format, state loader, delta-merge comparator |
| `src/main.zig` | Entry point (stub -- .COM loader not yet wired up) |

## Key patterns

- **Comptime dispatch table**: `execute.zig` builds a `[256]OpHandler` at comptime
  via `getHandler()`. Each entry is a function pointer. No runtime switch.
- **Parameterized comptime generators**: `makeArithModRM`, `makeLogicModRM`,
  `makeArithAccImm` generate type-safe handlers for all size/direction combos.
- **Group opcodes** (80-83, F6/F7, FE/FF, D0-D3): dispatch on the `reg` field
  of ModR/M inside the handler.
- **Prefix loop**: `step()` consumes segment override / LOCK / REP prefix bytes
  in a loop before dispatching the actual opcode.
- **PrefixState**: carries `seg_override: ?u16` and `rep_prefix` through to handlers.
- **push16/pop16 helpers**: handle SS:SP stack operations. `push16` implements the
  8086 PUSH SP quirk (pushes already-decremented SP).

## Test infrastructure

- Test JSON files go in `tests/` (gitignored). Download from SingleStepTests repo.
- Group opcodes use dotted filenames: `80.0.json`, `F6.5.json`, `FE.1.json`.
- `parseFinalState()` does delta-merge: SingleStepTests final state only includes
  changed registers, so it merges with initial state.
- `validateOpcodeWithMask(path, flags_mask)` masks undefined flag bits before
  comparison (e.g. AF on shifts, SF on MUL).
- `runTestFileWithMask()` returns pass/fail counts for tests with known edge
  cases (DAA, AAM divide-by-zero).
- File read limit is 200MB for large string op test files.

## Known limitations

- **DIV/IDIV overflow (INT 0)**: Pushes undefined flag bits to stack RAM.
  Hardware test RAM comparison fails. DIV logic is correct for non-overflow.
  Tests are commented out.
- **DAA/DAS**: 17/2000 edge cases with AL=0x9A-0x9F, AF=1, CF=0. Tests accept
  >95% pass rate.
- **MUL/IMUL SF**: Masked in tests. Underdocumented on real 8086.
- **F6/F7 groups 4-7**: MUL sets SF from high byte (AH for byte, DX for word).
  IMUL uses the same. AAM clears CF/OF/AF. AAD uses `add8()` for full flag
  effects including CF/OF.

## Conventions

- No magic numbers -- use named constants and enums.
- Zig 0.15 API: `std.debug.print` for output. `comptime` keyword is implicit
  for module-scope `const`. `packed` is a keyword, not usable as a variable name.
- Bus memory: heap-allocated via `page_allocator.create([1048576]u8)`.
