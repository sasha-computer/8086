# emu8086

An Intel 8086 CPU emulator in Zig that runs in the browser via WebAssembly.

Every implemented opcode is validated instruction-by-instruction against
[SingleStepTests/8086](https://github.com/SingleStepTests/8086) hardware-captured
test vectors -- traces from real 8086 silicon. 82 test groups passing across 294
test files.

## Try it

Build the WASM module and serve the web frontend:

```
zig build wasm
cp zig-out/web/emu8086.wasm web/
cd web && python3 serve.py
```

Open `http://localhost:8086`, load a `.COM` file, hit Run.

Three test programs are included in `web/`:

| File | Size | What it does |
|------|------|-------------|
| `hello.com` | 28 B | Prints "Hello from 8086!" |
| `fibonacci.com` | 94 B | Prints first 20 Fibonacci numbers |
| `count.com` | 35 B | Prints digits 1 through 9 |

## Building

Requires [Zig 0.15+](https://ziglang.org/download/).

```
zig build            # native binary
zig build wasm       # WebAssembly module (zig-out/web/emu8086.wasm)
zig build test       # run hardware validation tests
```

The WASM binary is ~24KB (`ReleaseSmall`).

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

Some opcodes have sub-group tests (e.g. `80.0.json`, `F6.5.json`). See the
[SingleStepTests repo](https://github.com/SingleStepTests/8086) for the full
file listing.

```
zig build test
```

## Architecture

```
src/
  cpu.zig           CPU state -- packed union registers, FLAGS, segments
  bus.zig           1MB flat memory, segment:offset addressing, I/O stubs
  decode.zig        Instruction fetch, ModR/M decode, effective address calc
  execute.zig       Comptime 256-entry dispatch table, all instruction handlers
  flags.zig         Flag computation (parity LUT, add/sub/logic flag helpers)
  test_runner.zig   JSON test suite parser, state loader, delta comparator
  main.zig          Native CLI entry point
  wasm_api.zig      WASM export layer (8 functions for browser bridge)
web/
  index.html        Browser frontend (HTML + CSS + minimal JS WASM shim)
  serve.py          Dev server with application/wasm MIME type
  *.com             Test .COM binaries
```

### Design decisions

- **Register file** uses packed unions so AX/AH/AL share storage naturally,
  matching real hardware layout.
- **Opcode dispatch** via a comptime 256-entry function pointer table. No
  runtime switch. Parameterized comptime generators (`makeArithModRM`,
  `makeLogicModRM`, etc.) produce type-safe handlers for all size/direction
  combinations.
- **Memory** is a flat `[1048576]u8` -- heap-allocated on native,
  static in WASM linear memory. Segment:offset resolved at the bus level
  with 20-bit address wrapping.
- **Flags** stored as individual bools, packed into the FLAGS register on demand.
- **WASM build** uses conditional compilation (`builtin.cpu.arch == .wasm32`)
  so the same core code compiles for both native and browser targets.
- **Web frontend** uses modern CSS for all UI interaction -- tab switching via
  radio buttons and `:has()` selectors, automatic dark/light mode via
  `light-dark()`, entry animations via `@starting-style`. The only JavaScript
  is a ~120-line shim for WASM instantiation and DOM updates.

### WASM API

The browser loads `emu8086.wasm` and calls these exported functions:

| Function | Purpose |
|----------|---------|
| `init()` | Zero CPU state, clear memory |
| `load_program(offset, len)` | Set up .COM execution (CS=DS=ES=SS=0, IP=offset, SP=FFFEh) |
| `step() -> u8` | Execute one instruction (0=ok, 1=halt, 2=unimplemented) |
| `run(n) -> u8` | Execute up to n instructions |
| `get_registers() -> ptr` | Pointer to 14 x u16 register snapshot |
| `get_memory_ptr() -> ptr` | Pointer to 1MB memory array |
| `get_output_buf() -> ptr` | Pointer to INT 21h text output buffer |
| `get_output_len() -> u32` | Bytes written to output buffer |

JS reads registers and memory directly from WASM linear memory via
`Uint8Array`/`Uint16Array` views at the returned pointer offsets.

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

### DOS interrupts (WASM only)

The WASM build intercepts INT 21h for .COM program support:

- **AH=02h** -- write character (DL) to output buffer
- **AH=09h** -- write '$'-terminated string (DS:DX) to output buffer
- **AH=4Ch** -- terminate program
- **INT 20h** -- terminate program

### Known limitations

- **DIV/IDIV overflow**: Division by zero triggers INT 0, which pushes FLAGS to
  the stack. Undefined flag bits in the pushed value cause RAM byte mismatches
  against hardware traces. The division logic itself is correct for all
  non-overflow cases.
- **DAA/DAS edge case**: 17/2000 test cases fail when AL is 0x9A-0x9F with
  AF=1 and CF=0. Underdocumented nibble-carry interaction on real 8086.
- **MUL/IMUL SF**: The sign flag after multiply is undefined on the 8086.
  Hardware behavior varies; tests mask SF for these opcodes.

## References

- [SingleStepTests/8086](https://github.com/SingleStepTests/8086) -- hardware-captured test vectors
- [Intel 8086 Family User's Manual](https://edge.edx.org/c4x/BITSPilani/EEE231/asset/8086_family_Users_Manual_1_.pdf)
- [8086 Opcode Map](http://www.mlsite.net/8086/)
