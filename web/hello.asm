; hello.com -- minimal DOS .COM program
; Assembled bytes are in hello.com (hand-assembled below)
;
; org 100h
; mov ah, 09h      ; DOS print string
; mov dx, msg      ; DS:DX -> message
; int 21h          ; call DOS
; mov ah, 4Ch      ; DOS terminate
; int 21h
; msg db 'Hello from 8086!', '$'
