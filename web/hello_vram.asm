; hello_vram.com - writes "HELLO 8086!" directly to text VRAM (B800:0000)
; Assemble: nasm -f bin -o hello_vram.com hello_vram.asm
org 0x100

    mov ax, 0xB800
    mov es, ax

    ; Write "HELLO 8086!" at row 0, col 0 with white-on-blue (attr 0x1F)
    xor di, di
    mov si, msg
    mov ah, 0x1F        ; attribute: white on blue
.loop:
    lodsb
    or al, al
    jz .done
    stosw               ; write char (AL) + attr (AH) to ES:DI
    jmp .loop
.done:

    ; Also draw a colored bar on row 2
    mov di, 320         ; row 2, col 0 (2 * 80 * 2 = 320)
    mov cx, 16
    mov al, 0xDB        ; full block character
    mov bl, 0
.bar:
    mov ah, bl          ; foreground = color index, bg = black
    stosw
    inc bl
    loop .bar

    ; Use INT 10h teletype to print on row 4
    mov ah, 0x02        ; set cursor position
    mov bh, 0           ; page 0
    mov dh, 4           ; row 4
    mov dl, 0           ; col 0
    int 0x10

    mov si, msg2
.tty:
    lodsb
    or al, al
    jz .halt
    mov ah, 0x0E        ; teletype output
    mov bh, 0
    int 0x10
    jmp .tty

.halt:
    hlt

msg db 'HELLO 8086!', 0
msg2 db 'Teletype output via INT 10h works!', 0
