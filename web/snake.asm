; snake.com - Text-mode snake game with proper body (pure 8086)
; Uses INT 10h (video) and INT 16h (keyboard)
; Assemble: nasm -f bin -o snake.com snake.asm
cpu 8086
org 0x100

COLS equ 80
ROWS equ 25
VRAM equ 0xB800
ROW_BYTES equ COLS*2
MAX_LEN equ 200            ; max snake body segments

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

    ; Init snake: 3 segments going right from center
    mov word [head], 2      ; head index into ring buffer
    mov word [tail], 0      ; tail index
    mov word [slen], 3      ; current length
    mov byte [dir], 0       ; 0=right
    mov word [score], 0
    mov byte [grow], 0      ; growth pending

    ; Place initial body: positions (38,12), (39,12), (40,12)
    mov word [body_x + 0], 38
    mov word [body_y + 0], 12
    mov word [body_x + 2], 39
    mov word [body_y + 2], 12
    mov word [body_x + 4], 40
    mov word [body_y + 4], 12

    ; Draw initial body
    mov ax, 38
    mov bx, 12
    call calc_offset
    mov word [es:di], 0x0AFE  ; body block, green
    mov ax, 39
    mov bx, 12
    call calc_offset
    mov word [es:di], 0x0AFE
    mov ax, 40
    mov bx, 12
    call calc_offset
    mov word [es:di], 0x0A02  ; head: smiley, green

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

    cmp ah, 0x48
    je .set_up
    cmp ah, 0x50
    je .set_down
    cmp ah, 0x4B
    je .set_left
    cmp ah, 0x4D
    je .set_right
    cmp ah, 0x01
    je quit
    jmp .no_key

.set_up:
    cmp byte [dir], 1
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
    ; Get current head position
    mov si, [head]
    shl si, 1              ; word index
    mov ax, [body_x + si]
    mov bx, [body_y + si]

    ; Move based on direction
    cmp byte [dir], 0
    je .mr
    cmp byte [dir], 1
    je .md
    cmp byte [dir], 2
    je .ml
    dec bx
    jmp .moved
.mr:
    inc ax
    jmp .moved
.md:
    inc bx
    jmp .moved
.ml:
    dec ax

.moved:
    ; Wall collision
    cmp ax, 1
    jl game_over
    cmp ax, COLS-2
    jg game_over
    cmp bx, 1
    jl game_over
    cmp bx, ROWS-2
    jg game_over

    ; Turn old head into body segment
    mov si, [head]
    shl si, 1
    push ax
    push bx
    mov ax, [body_x + si]
    mov bx, [body_y + si]
    call calc_offset
    mov word [es:di], 0x02FE  ; body: block, dark green
    pop bx
    pop ax

    ; Advance head index in ring buffer
    mov si, [head]
    inc si
    cmp si, MAX_LEN
    jl .no_wrap_head
    xor si, si
.no_wrap_head:
    mov [head], si

    ; Store new head position
    shl si, 1
    mov [body_x + si], ax
    mov [body_y + si], bx

    ; Draw new head
    call calc_offset
    mov word [es:di], 0x0A02  ; smiley, bright green

    ; Check food collision
    mov ax, [body_x + si]
    cmp ax, [food_x]
    jne .no_food
    mov bx, [body_y + si]
    cmp bx, [food_y]
    jne .no_food

    ; Ate food
    inc word [score]
    inc word [slen]
    mov byte [grow], 1
    call place_food
    jmp .after_tail

.no_food:
    ; Check if we need to grow
    cmp byte [grow], 0
    jne .skip_erase

    ; Erase tail
    mov si, [tail]
    shl si, 1
    mov ax, [body_x + si]
    mov bx, [body_y + si]
    call calc_offset
    mov word [es:di], 0x0720  ; space

    ; Advance tail index
    mov si, [tail]
    inc si
    cmp si, MAX_LEN
    jl .no_wrap_tail
    xor si, si
.no_wrap_tail:
    mov [tail], si
    jmp .after_tail

.skip_erase:
    mov byte [grow], 0

.after_tail:
    ; Draw food (in case it was just placed)
    mov ax, [food_x]
    mov bx, [food_y]
    call calc_offset
    mov word [es:di], 0x0C04  ; diamond, red

    ; Draw score
    call draw_score

    ; Delay: scale by direction so vertical/horizontal speed feels equal.
    ; Text cells are 8x16 px, so vertical moves cover 2x the pixels.
    ; Horizontal (dir 0 or 2): 3 outer loops ~400K insns.
    ; Vertical (dir 1 or 3): 6 outer loops ~800K insns (2x slower).
    mov cl, [dir]
    cmp cl, 1
    je .vert_delay
    cmp cl, 3
    je .vert_delay
    mov cx, 3              ; horizontal
    jmp .delay_outer
.vert_delay:
    mov cx, 6              ; vertical
.delay_outer:
    push cx
    xor cx, cx              ; 65536 iterations
.delay_inner:
    dec cx
    jnz .delay_inner
    pop cx
    loop .delay_outer
    jmp game_loop

game_over:
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
    mov bl, 0x4F
    mov cx, 1
    mov bh, 0
    int 0x10
    inc dl
    mov ah, 0x02
    int 0x10
    jmp .print_go

.wait_key:
    mov ah, 0x00
    int 0x16
    cmp ah, 0x01
    je quit
    jmp start

quit:
    mov ax, 0x4C00
    int 0x21

; ---- Subroutines ----

calc_offset:
    push ax
    push dx
    mov di, bx
    mov dx, ROW_BYTES
    push ax
    mov ax, di
    mul dx
    mov di, ax
    pop ax
    shl ax, 1
    add di, ax
    pop dx
    pop ax
    ret

draw_border:
    push cx
    push di
    push bx
    ; Top row
    xor di, di
    mov cx, COLS
    mov ax, 0x0BCD
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
    ; Sides
    mov cx, ROWS
    xor bx, bx
.sides:
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

place_food:
    push ax
    push bx
    push dx
    ; Simple PRNG
    mov ax, [score]
    shl ax, 1
    add ax, [body_x]       ; use first body entry as entropy
    add ax, 37
    xor dx, dx
    mov bx, 76
    div bx
    add dx, 2
    mov [food_x], dx
    ; Y
    mov ax, [score]
    shl ax, 1
    shl ax, 1
    add ax, [body_y]
    add ax, 53
    xor dx, dx
    mov bx, 21
    div bx
    add dx, 2
    mov [food_y], dx
    pop dx
    pop bx
    pop ax
    ret

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
dir     db 0
grow    db 0
head    dw 2
tail    dw 0
slen    dw 3
score   dw 0
food_x  dw 20
food_y  dw 8
score_msg db 'Score:', 0
game_over_msg db 'GAME OVER', 0

; Ring buffer for body positions (MAX_LEN entries)
body_x: times MAX_LEN dw 0
body_y: times MAX_LEN dw 0
