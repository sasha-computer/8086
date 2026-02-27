# Games for emu8086

Research into running real 8086 games in the emulator. The emulator already loads
`.COM` files and stubs INT 21h for text output. Adding a few more interrupt
handlers and a video canvas would unlock dozens of playable games in the browser.

## What works today

The WASM build intercepts:

- INT 21h AH=02h -- write character
- INT 21h AH=09h -- write $-terminated string
- INT 21h AH=4Ch -- terminate
- INT 20h -- terminate

This is enough for text-output programs (hello world, fibonacci, etc.) but not
for interactive games, which need keyboard input and video output.

## What games need

### INT 10h -- BIOS video services

Almost every 8086 game uses INT 10h for display. Priority sub-functions:

| AH | Function | Used by |
|----|----------|---------|
| 00h | Set video mode | Everything -- mode 03h (80x25 text) and mode 13h (320x200x256 graphics) |
| 02h | Set cursor position | Text-mode games |
| 09h | Write character with attribute at cursor | Text-mode rendering |
| 0Ah | Write character at cursor | Text-mode rendering |
| 0Eh | Teletype output (write char + advance cursor) | Simple output |
| 0Ch | Write pixel (graphics mode) | Pixel-based games |
| 0Dh | Read pixel (graphics mode) | Collision detection |
| 0Fh | Get current video mode | Mode queries |

**Text mode (03h):** 80x25 grid, each cell is 2 bytes at B800:0000 (character +
attribute byte with fg/bg color). Many boot sector games and DOS games use this
directly.

**Graphics mode (13h):** 320x200, 1 byte per pixel at A000:0000. The classic
DOS game mode. Used by more complex games.

### INT 16h -- BIOS keyboard services

Every interactive game needs keyboard input:

| AH | Function | Purpose |
|----|----------|---------|
| 00h | Read key (blocking) | Wait for keypress, returns AH=scan code, AL=ASCII |
| 01h | Check key buffer (non-blocking) | ZF=1 if no key, ZF=0 if key ready. Does not consume. |
| 02h | Get shift key status | Check Ctrl/Alt/Shift state |

Most games use AH=01h in a loop (poll for input without blocking) then AH=00h
to consume the key when one is available.

### Direct memory-mapped video

Many games bypass INT 10h entirely and write directly to video memory:

- **B800:0000** -- text mode framebuffer (80x25 x 2 bytes = 4000 bytes)
- **A000:0000** -- graphics mode framebuffer (320x200 = 64000 bytes)

The emulator's flat 1MB memory already covers these addresses. The web frontend
just needs to read from these regions and render them to a `<canvas>`.

### Timer (INT 1Ch / port 40h-43h)

Some games hook INT 1Ch (timer tick, ~18.2 Hz) for animation timing. Not
strictly required for many games but needed for smooth animation in more
polished ones. The emulator could fire a synthetic INT 1Ch every N instructions
to approximate this.

## Implementation plan

### Phase 1: Text-mode video (quickest win)

1. Add a `<canvas>` element to the web frontend
2. After each `run()` call, read 4000 bytes from address 0xB8000 in WASM memory
3. Render each character cell using a bitmap font (8x16 CP437 glyphs)
4. Support the 16-color CGA text attribute byte (4-bit fg, 4-bit bg)
5. Stub INT 10h AH=00h to set a mode flag, AH=02h/09h/0Ah/0Eh for cursor ops

This unlocks: text-mode boot sector games, many simple DOS games, anything that
writes to B800:0000.

### Phase 2: Keyboard input

1. Capture keydown/keyup events in JS
2. Map browser key codes to 8086 scan codes
3. Maintain a small key buffer in WASM memory
4. Implement INT 16h AH=00h (blocking read) and AH=01h (peek)
5. Export a `push_key(scan_code, ascii)` function from WASM

This unlocks: all interactive games.

### Phase 3: Graphics mode 13h

1. Implement INT 10h AH=00h mode 13h (set 320x200x256 mode)
2. Read 64000 bytes from address 0xA0000 in WASM memory
3. Map VGA palette indices to RGB colors (default VGA palette)
4. Render to canvas, scaled up (e.g. 2x or 3x)
5. Implement INT 10h AH=0Ch (write pixel) and AH=0Dh (read pixel)

This unlocks: graphical DOS games, demoscene productions, more complex boot
sector games.

### Phase 4: Timer and polish

1. Fire synthetic INT 1Ch at ~18.2 Hz (every ~65536 instructions at 1 MHz)
2. Add INT 12h (memory size) returning 640 KB
3. Add basic speaker beep via Web Audio API (INT 21h already beeps on some games)
4. Add game speed control slider in the UI

## Game sources

### Boot sector games (512 bytes, self-contained)

These are the most impressive option -- entire games in 512 bytes. They boot
from a raw disk image and use BIOS interrupts directly.

**Curated master list (31 games):**
https://gist.github.com/XlogicX/8204cf17c432cc2b968d138eb639494e

Notable entries:

| Game | Author | Notes |
|------|--------|-------|
| Snake | Multiple | Classic snake, fits in boot sector |
| Tetris | nanochess | Full color, no score display |
| PacMan (text) | nanochess | Ghost AI, power pills, text mode |
| PacMan (graphics) | -- | Smooth graphics mode version |
| Minesweeper | -- | Mouse-based (would need INT 33h) |
| Dino Runner | -- | Chrome t-rex clone |
| Pillman | -- | Pac-Man variant |
| bootRogue | nanochess | Roguelike in a boot sector |
| bootOS | nanochess | Tiny OS that can run programs |
| Sokoban | maksimKorzh | Push-box puzzle |

**Boot games collection:** https://github.com/maksimKorzh/boot-games
Source code and `.img` files for several boot sector games. Includes a Sokoban
implementation.

### DOS .COM games (already our format)

These load at 0000:0100 and use INT 21h + INT 10h + INT 16h:

**Balloon Shooting Game**
https://github.com/Rezve/8086-Microprocessor-Game-in-Assembly-Language
- Tested in emu8086 emulator
- Player shoots arrows at balloons
- Uses INT 10h text mode, INT 16h keyboard
- Single `game.asm` source file

**Rocket Shooting Game**
https://github.com/MichaelKMalak/Rocket-Shooting
- x86 assembly, tested on DOSBox and emu8086
- Side-scrolling shooter
- Uses INT 10h, INT 16h, INT 21h

**Assembly Games Collection (FASM)**
https://github.com/fabianosalles/assembly-games
- Multiple games targeting 8086
- Built with FASM (Flat Assembler)
- Intel syntax source code

### Larger game projects

**Space Invaders (bootable)**
https://github.com/flxbe/asm-space-invaders
- Complete Space Invaders clone
- Includes its own bootloader
- Built with NASM
- Uses graphics mode

**Pong (bootable)**
https://github.com/EndPositive/VU-Pong-assembly
- x86 AT&T syntax
- Menu screen, highscores
- Wall moves closer as score increases

### Classic DOS games (advanced, need more stubs)

If the emulator gets more complete DOS support, these become possible:

- **8086tiny test suite** includes several classic games
  https://github.com/adriancable/8086tiny (reference emulator with BIOS)
- QBasic Gorillas / Nibbles (need BASIC interpreter, not realistic)
- Early Sierra games, Sopwith, etc. (need full DOS + BIOS, way out of scope)

## How to load boot sector games

Boot sector games expect to be loaded at 0000:7C00 (the BIOS boot address)
rather than 0000:0100 (.COM load address). The emulator needs a second load
mode:

```
load_boot_sector(offset, len)
  - Load 512 bytes at 0000:7C00
  - Set CS:IP to 0000:7C00
  - Set DL to 0x80 (first hard drive, expected by some games)
  - Set SS:SP to 0000:7C00 (stack grows down below boot sector)
```

This could be a toggle in the web UI: "Load as .COM" vs "Load as boot sector".

## Suggested first targets

In order of implementation difficulty:

1. **Text-mode Snake** -- needs INT 10h text mode + INT 16h keyboard. A classic
   demo that proves the video and input pipeline works end to end.

2. **Sokoban (boot-games)** -- text mode puzzle game. No timing-critical code,
   turn-based input. Good for validating correctness.

3. **Tetris (boot sector)** -- needs graphics mode or colored text mode.
   Great visual demo for the project README.

4. **Space Invaders** -- needs graphics mode 13h + timer. The "wow" demo that
   shows the emulator is real.

## CP437 font

Text-mode rendering needs the Code Page 437 bitmap font (the IBM PC character
set). Each glyph is 8x16 pixels, 256 characters, 4096 bytes total.

Sources:
- https://github.com/susam/pcface (CP437 font data as arrays)
- https://int10h.org/oldschool-pc-fonts/ (pixel-perfect recreations)
- The font can be embedded directly in the JS frontend as a base64 PNG sprite
  sheet or a typed array of glyph bitmaps.

## VGA palette

Mode 13h uses a 256-color palette. The default VGA palette is well-documented:
- First 16 entries match CGA colors
- Entries 16-255 are a color cube + grayscale ramp
- Full palette data: https://en.wikipedia.org/wiki/Video_Graphics_Array#Color_palette

The palette can be a static 256x3 byte array in JS. Some games reprogram the
palette via port 3C8h/3C9h (OUT instructions), which would need I/O port
handling in the emulator.

## Scan code table

Mapping browser KeyboardEvent.code to 8086 scan codes:

| Key | Scan code | ASCII |
|-----|-----------|-------|
| Esc | 01h | 1Bh |
| Up | 48h | 00h (extended) |
| Down | 50h | 00h |
| Left | 4Bh | 00h |
| Right | 4Dh | 00h |
| Space | 39h | 20h |
| Enter | 1Ch | 0Dh |
| A-Z | 1Eh-2Ch | 41h-5Ah |
| 0-9 | 02h-0Bh | 30h-39h |

Extended keys (arrows, function keys) return AL=00h with the scan code in AH
from INT 16h AH=00h.

## References

- [List of Boot Sector Games](https://gist.github.com/XlogicX/8204cf17c432cc2b968d138eb639494e)
- [maksimKorzh/boot-games](https://github.com/maksimKorzh/boot-games)
- [nanochess boot sector games](https://nanochess.org/boot.html)
- [8086tiny](https://github.com/adriancable/8086tiny) -- reference C emulator with full BIOS
- [RBIL (Ralf Brown's Interrupt List)](http://www.ctyme.com/rbrown.htm) -- definitive interrupt reference
- [OSDev VGA Resources](https://wiki.osdev.org/VGA_Resources)
- [CP437 character set](https://en.wikipedia.org/wiki/Code_page_437)
- [IBM PC scan codes](https://www.win.tue.nl/~aeb/linux/kbd/scancodes-1.html)
