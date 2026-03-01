# CLAUDE.md

## Project

Intel 8086 CPU emulator in Zig 0.15. Runs natively and in the browser via WASM.
Validated against SingleStepTests/8086 hardware-captured test vectors (294 JSON
files, 82 test groups).

## Build and test

```
zig build              # native binary + debugger
zig build wasm         # WASM module -> zig-out/web/emu8086.wasm
zig build test         # hardware validation tests (requires JSON files in tests/)
zig build test-snake   # snake game integration tests (loads web/snake.com)
zig build dbg -- web/snake.com  # run native debugger (interactive, needs TTY)
```

After `zig build wasm`, copy `zig-out/web/emu8086.wasm` to `web/` before serving.

Tests parse ~700MB of JSON and run hundreds of thousands of individual test cases.

## Source layout

| File | Purpose |
|------|---------|
| `src/cpu.zig` | CPU state: packed union registers (AX/AH/AL share storage), FLAGS as bools, segments |
| `src/bus.zig` | 1MB flat memory, segment:offset with 20-bit wrap. Conditional compilation: `page_allocator` on native, static array on WASM. Output buffer and halted flag for DOS support. |
| `src/decode.zig` | Instruction fetch from CS:IP, ModR/M decode, effective address resolution |
| `src/execute.zig` | Comptime 256-entry dispatch table, all instruction handlers, prefix loop. INT 10h/16h/21h/20h interception when `bus.intercept_bios` is set (WASM default + native debugger). |
| `src/flags.zig` | Flag computation: comptime parity LUT, add/sub/inc/dec/logic flag helpers |
| `src/test_runner.zig` | JSON parser for SingleStepTests format, state loader, delta-merge comparator |
| `src/main.zig` | Native CLI entry point |
| `src/wasm_api.zig` | WASM export layer: exported functions, owns static Cpu and Bus instances |
| `web/index.html` | Browser frontend. CSS handles all UI interaction (tabs, theming). JS for WASM bridge, CP437 text display renderer, keyboard input. |
| `web/cp437.js` | CP437 8x16 bitmap font data (256 glyphs, 16 bytes each) for text-mode display |
| `web/serve.py` | Dev server with `application/wasm` MIME type (`uv run web/serve.py`) |
| `web/*.com` | Test .COM binaries (hello, fibonacci, count, snake, hello_vram) |
| `src/debugger.zig` | Native CLI debugger: loads .COM, renders text VRAM to terminal via ANSI, raw keyboard input. Headless mode (`--headless N`) for scripted testing, key injection (`--key INSN:SC:ASCII`). |
| `src/snake_test.zig` | Integration tests for the snake game: loads snake.com, injects keys, asserts VRAM state and timing. |

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
- **Conditional compilation**: `builtin.cpu.arch == .wasm32` gates WASM-specific
  behavior (static memory, DOS interrupt interception).

## WASM specifics

- `wasm_api.zig` is the WASM entry point (not `main.zig`).
- Bus uses static arrays instead of `page_allocator` on WASM.
- INT 21h (AH=02, 09, 4C) and INT 20h are intercepted in WASM builds for .COM
  program support. Native builds go through the IVT for hardware accuracy.
- INT 10h (video BIOS) and INT 16h (keyboard BIOS) are intercepted on WASM for
  text-mode game support. Handles set mode, cursor, scroll, read/write char, teletype.
- WASM exports: `init`, `step`, `run`, `load_program`, `load_boot_sector`,
  `get_registers`, `get_memory_ptr`, `get_output_buf`, `get_output_len`,
  `push_key`, `get_video_mode`, `is_waiting_for_key`, `get_cursor_pos`.
- JS reads WASM linear memory directly via `Uint8Array` views at pointer offsets.

## Web frontend

- All UI interaction is CSS-only: tab switching via hidden radio buttons and
  `:has()` selectors, dark/light mode via `color-scheme: light dark` and
  `light-dark()`, entry animations via `@starting-style`.
- Custom HTML elements (`<emu-shell>`, `<reg-cell>`, `<flag-bit>`, etc.) for
  semantic markup.
- Display tab renders 80x25 text mode via canvas: reads VRAM at 0xB8000,
  draws CP437 glyphs with CGA 16-color palette, runs every frame.
- Keyboard events mapped to 8086 scan codes, pushed to emulator via `push_key`.
- Load mode selector: .COM (loads at 0100h) or Boot Sector (loads at 7C00h).
- JS is limited to: WASM loading, DOM text updates, display rendering,
  keyboard bridge, requestAnimationFrame loop.

## Test infrastructure

- Test JSON files go in `tests/` (gitignored). Download from SingleStepTests repo.
- Group opcodes use dotted filenames: `80.0.json`, `F6.5.json`, `FE.1.json`.
- `parseFinalState()` does delta-merge: final state only includes changed registers.
- `validateOpcodeWithMask(path, flags_mask)` masks undefined flag bits before
  comparison (e.g. AF on shifts, SF on MUL).
- `runTestFileWithMask()` returns pass/fail counts for tests with known edge
  cases (DAA, AAM divide-by-zero).
- File read limit is 200MB for large string op test files.

## Known limitations

- **DIV/IDIV overflow (INT 0)**: Pushes undefined flag bits to stack RAM.
  Hardware test RAM comparison fails. DIV logic is correct for non-overflow.
- **DAA/DAS**: 17/2000 edge cases with AL=0x9A-0x9F, AF=1, CF=0.
- **MUL/IMUL SF**: Masked in tests. Underdocumented on real 8086.

## Conventions

- No magic numbers -- use named constants and enums.
- Zig 0.15 API: `comptime` keyword is implicit for module-scope `const`.
- All new instructions must be validated against hardware test vectors.
- Web changes: rebuild WASM with `zig build wasm` and copy to `web/`.
