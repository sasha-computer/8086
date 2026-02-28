; snake.com - Simple text-mode snake game (pure 8086)
; Uses INT 10h (video) and INT 16h (keyboard)
; Assemble: nasm -f bin -o snake.com snake.asm
cpu 8086
org 0x100

COLS equ 80
ROWS equ 25
VRAM equ 0xB800
ROW_BYTES equ COLS*2   ; 160 bytes per row

section .text
start:
    ; Set video mode 03h (80x25 text, clears screen)
    mov ax, 0x0003
    int 0x10

    ; Hide cursor
    mov ah, 0x01
    mov cx, 0x2607
    int 0x10

    ; Init ES to video segment
    mov ax, VRAM
    mov es, ax

    ; Draw border
    call draw_border

    ; Init snake at center
    mov word [snake_x], 40
    mov word [snake_y], 12
    mov byte [dir], 0       ; 0=right, 1=down, 2=left, 3=up
    mov word [score], 0

    ; Init tail behind head
    mov word [tail_x], 39
    mov word [tail_y], 12

    ; Place initial food
    call place_food

game_loop:
    ; Check for key (non-blocking)
    mov ah, 0x01
    int 0x16
    jz .no_key

    ; Read the key
    mov ah, 0x00
    int 0x16

    ; AH = scan code
    cmp ah, 0x48            ; up
    je .set_up
    cmp ah, 0x50            ; down
    je .set_down
    cmp ah, 0x4B            ; left
    je .set_left
    cmp ah, 0x4D            ; right
    je .set_right
    cmp ah, 0x01            ; ESC
    je quit
    jmp .no_key

.set_up:
    cmp byte [dir], 1       ; can't reverse
    je .no_key
    mov byte [dir], 3
    jmp .no_key
.set_down:
    cmp byte [dir], 3
    je .no_key
    mov byte [dir], 1
    jmp .no_key
.set_left:
    cmp byte [dir], 0
    je .no_key
    mov byte [dir], 2
    jmp .no_key
.set_right:
    cmp byte [dir], 2
    je .no_key
    mov byte [dir], 0

.no_key:
    ; Save old position as tail
    mov ax, [snake_x]
    mov [tail_x], ax
    mov ax, [snake_y]
    mov [tail_y], ax

    ; Move snake head based on direction
    cmp byte [dir], 0
    je .move_right
    cmp byte [dir], 1
    je .move_down
    cmp byte [dir], 2
    je .move_left
    ; else up
    dec word [snake_y]
    jmp .moved
.move_right:
    inc word [snake_x]
    jmp .moved
.move_down:
    inc word [snake_y]
    jmp .moved
.move_left:
    dec word [snake_x]

.moved:
    ; Check wall collision
    cmp word [snake_x], 1
    jl game_over
    cmp word [snake_x], COLS-2
    jg game_over
    cmp word [snake_y], 1
    jl game_over
    cmp word [snake_y], ROWS-2
    jg game_over

    ; Check food collision
    mov ax, [snake_x]
    cmp ax, [food_x]
    jne .no_food
    mov ax, [snake_y]
    cmp ax, [food_y]
    jne .no_food
    ; Ate food!
    inc word [score]
    call place_food
    jmp .draw_head          ; skip tail erase (snake grows)

.no_food:
    ; Erase tail
    mov ax, [tail_x]
    mov bx, [tail_y]
    call calc_offset
    mov word [es:di], 0x0720  ; space with gray attr

.draw_head:
    ; Draw head
    mov ax, [snake_x]
    mov bx, [snake_y]
    call calc_offset
    mov word [es:di], 0x0A02  ; smiley, green on black

    ; Draw food
    mov ax, [food_x]
    mov bx, [food_y]
    call calc_offset
    mov word [es:di], 0x0C04  ; diamond, red on black

    ; Draw score
    call draw_score

    ; Delay loop
    mov cx, 0x0002
.delay_outer:
    push cx
    mov cx, 0x0100          ; 256 iterations (fast in emulator)
.delay_inner:
    dec cx
    jnz .delay_inner
    pop cx
    loop .delay_outer

    jmp game_loop

game_over:
    ; Print "GAME OVER" at center
    mov ah, 0x02
    mov bh, 0
    mov dh, 12
    mov dl, 35
    int 0x10

    mov si, game_over_msg
.print_go:
    lodsb
    or al, al
    jz .wait_key
    mov ah, 0x09
    mov bl, 0x4F            ; white on red
    mov cx, 1
    mov bh, 0
    int 0x10
    ; Advance cursor
    inc dl
    mov ah, 0x02
    int 0x10
    jmp .print_go

.wait_key:
    mov ah, 0x00
    int 0x16
    cmp ah, 0x01            ; ESC to quit
    je quit
    jmp start               ; any other key restarts

quit:
    mov ax, 0x4C00
    int 0x21

; ---- Subroutines ----

; calc_offset: AX=col, BX=row -> DI = VRAM offset
calc_offset:
    push ax
    push dx
    ; DI = row * 160 + col * 2
    mov di, bx
    mov dx, ROW_BYTES
    push ax
    mov ax, di
    mul dx              ; AX = row * 160
    mov di, ax
    pop ax
    shl ax, 1           ; col * 2
    add di, ax
    pop dx
    pop ax
    ret

; Draw border
draw_border:
    push cx
    push di
    push bx
    ; Top row
    xor di, di
    mov cx, COLS
    mov ax, 0x0BCD          ; double horiz, cyan
.top:
    stosw
    loop .top

    ; Bottom row
    mov di, (ROWS-1)*ROW_BYTES
    mov cx, COLS
    mov ax, 0x0BCD
.bottom:
    stosw
    loop .bottom

    ; Side columns
    mov cx, ROWS
    xor bx, bx
.sides:
    ; Left column: row bx
    mov ax, ROW_BYTES
    push dx
    push cx
    mov cx, bx
    xor di, di
    jcxz .at_zero
.mul_loop:
    add di, ROW_BYTES
    loop .mul_loop
.at_zero:
    pop cx
    pop dx
    mov word [es:di], 0x0BBA
    add di, (COLS-1)*2
    mov word [es:di], 0x0BBA
    inc bx
    loop .sides

    ; Corners
    mov word [es:0], 0x0BC9
    mov word [es:(COLS-1)*2], 0x0BBB
    mov word [es:(ROWS-1)*ROW_BYTES], 0x0BC8
    mov word [es:(ROWS-1)*ROW_BYTES+(COLS-1)*2], 0x0BBC
    pop bx
    pop di
    pop cx
    ret

; Place food at pseudo-random position
place_food:
    push ax
    push bx
    push dx
    ; X: 2..77
    mov ax, [snake_x]
    add ax, [snake_y]
    add ax, [score]
    add ax, 7
    xor dx, dx
    mov bx, 76
    div bx
    add dx, 2
    mov [food_x], dx
    ; Y: 2..22
    mov ax, [snake_x]
    xor ax, [snake_y]
    add ax, [score]
    add ax, 13
    xor dx, dx
    mov bx, 21
    div bx
    add dx, 2
    mov [food_y], dx
    pop dx
    pop bx
    pop ax
    ret

; Draw score at top-right
draw_score:
    push ax
    push bx
    push cx
    push dx
    mov ah, 0x02
    mov bh, 0
    mov dh, 0
    mov dl, 70
    int 0x10

    mov si, score_msg
.pr:
    lodsb
    or al, al
    jz .num
    mov ah, 0x0E
    mov bh, 0
    int 0x10
    jmp .pr
.num:
    mov ax, [score]
    mov bx, 10
    xor cx, cx
.div_loop:
    xor dx, dx
    div bx
    push dx
    inc cx
    or ax, ax
    jnz .div_loop
.print_digits:
    pop dx
    add dl, '0'
    mov ah, 0x0E
    mov al, dl
    mov bh, 0
    int 0x10
    loop .print_digits

    pop dx
    pop cx
    pop bx
    pop ax
    ret

; ---- Data ----
snake_x dw 40
snake_y dw 12
tail_x  dw 39
tail_y  dw 12
food_x  dw 20
food_y  dw 8
dir     db 0
score   dw 0
score_msg db 'Score:', 0
game_over_msg db 'GAME OVER', 0
