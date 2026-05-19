; Matrix rain – pure x86-64 Linux NASM assembly
; /dev/urandom  |  TIOCGWINSZ  |  ANSI escape codes  |  no libc

DEFAULT REL
global _start

; ── constants ─────────────────────────────────────────────────────────────────
MAX_COLS    equ 512
BUF_SIZE    equ 65536
RAND_BUF    equ 256
MIN_LEN     equ 6
MAX_LEN     equ 28
MIN_SPEED   equ 1
MAX_SPEED   equ 4
TIOCGWINSZ  equ 0x5413
SA_RESTORER equ 0x04000000

section .bss
    ws_row      resw 1
    ws_col      resw 1
    ws_xpixel   resw 1
    ws_ypixel   resw 1
    rows        resq 1
    cols        resq 1
    col_head    resq MAX_COLS
    col_len     resq MAX_COLS
    col_speed   resq MAX_COLS
    col_timer   resq MAX_COLS
    col_active  resb MAX_COLS
    wbuf        resb BUF_SIZE
    wbuf_pos    resq 1
    randbuf     resb RAND_BUF
    rand_pos    resq 1
    urand_fd    resq 1
    dec_scratch resb 32
    sigact      resb 32         ; kernel_sigaction: handler,flags,restorer,mask

section .data
    dev_urandom     db "/dev/urandom", 0

    ; startup / exit sequences
    seq_hide        db 0x1b, "[?25l"
    seq_hide_len    equ $ - seq_hide
    seq_show        db 0x1b, "[0m", 0x1b, "[?25h", 0x0a
    seq_show_len    equ $ - seq_show
    seq_cls         db 0x1b, "[2J", 0x1b, "[H"
    seq_cls_len     equ $ - seq_cls

    ; cell colors
    clr_head        db 0x1b, "[1;97m"      ; bright white  – leading char
    clr_head_len    equ $ - clr_head
    clr_bright      db 0x1b, "[1;32m"      ; bright green  – 1-2 behind head
    clr_bright_len  equ $ - clr_bright
    clr_normal      db 0x1b, "[0;32m"      ; normal green  – mid trail
    clr_normal_len  equ $ - clr_normal
    clr_dark        db 0x1b, "[2;32m"      ; dim green     – tail
    clr_dark_len    equ $ - clr_dark
    clr_erase       db 0x1b, "[0m "        ; reset + space – erase cell
    clr_erase_len   equ $ - clr_erase

    chars   db "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            db "0123456789@#$%^&*|/<>[]{}:;"
    chars_len equ $ - chars

    ; nanosleep timespec  ~33 ms ≈ 30 fps
    tv_sec  dq 0
    tv_nsec dq 33000000

section .text

; ── signal handler ────────────────────────────────────────────────────────────
; Called on SIGINT / SIGTERM.  Restore terminal and exit(0).
sig_handler:
    mov     rax, 1
    mov     rdi, 1
    lea     rsi, [seq_show]
    mov     rdx, seq_show_len
    syscall
    xor     rdi, rdi
    mov     rax, 60
    syscall

; Restorer trampoline required by the kernel when SA_RESTORER is set.
; (We never actually return from sig_handler, so this is for correctness only.)
sig_restorer:
    mov     rax, 15             ; rt_sigreturn
    syscall

; ── flush: write wbuf[0..wbuf_pos) to stdout ─────────────────────────────────
flush:
    mov     rdx, [wbuf_pos]
    test    rdx, rdx
    jz      .done
    mov     rax, 1              ; write
    mov     rdi, 1              ; stdout
    lea     rsi, [wbuf]
    syscall
    mov     qword [wbuf_pos], 0
.done:
    ret

; ── buf_byte: append al to wbuf (flushes first if almost full) ───────────────
buf_byte:
    mov     rcx, [wbuf_pos]
    cmp     rcx, BUF_SIZE - 64
    jb      .store
    push    rax                 ; preserve al across flush (flush clobbers rax)
    call    flush
    pop     rax
    mov     rcx, [wbuf_pos]
.store:
    mov     [wbuf + rcx], al
    inc     rcx
    mov     [wbuf_pos], rcx
    ret

; ── buf_bytes: append mem[rsi .. rsi+rdx) to wbuf ───────────────────────────
; Clobbers: rax, rcx.  Preserves: everything else (rbx/r12/r13 saved).
buf_bytes:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rsi            ; source ptr
    mov     r12, rdx            ; byte count
    xor     r13, r13            ; index
.lp:
    cmp     r13, r12
    jge     .done
    movzx   eax, byte [rbx + r13]
    call    buf_byte
    inc     r13
    jmp     .lp
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── buf_dec: append decimal representation of rax to wbuf ────────────────────
; Clobbers: rax, rdx, rcx.  Preserves: rbx/r12/r13 (saved).
buf_dec:
    push    rbx
    push    r12
    push    r13
    lea     rbx, [dec_scratch]
    xor     r12, r12            ; digit count
    test    rax, rax
    jnz     .cvt
    mov     byte [rbx], '0'
    mov     r12, 1
    jmp     .emit
.cvt:
    mov     r13, rax
.dloop:
    test    r13, r13
    jz      .rev
    xor     rdx, rdx
    mov     rax, r13
    mov     rcx, 10
    div     rcx
    mov     r13, rax
    add     dl, '0'
    mov     [rbx + r12], dl
    inc     r12
    jmp     .dloop
.rev:
    ; digits are in reverse order – flip them
    xor     r13, r13
    mov     rcx, r12
    dec     rcx
.rlp:
    cmp     r13, rcx
    jge     .emit
    movzx   eax, byte [rbx + r13]
    movzx   edx, byte [rbx + rcx]
    mov     [rbx + r13], dl
    mov     [rbx + rcx], al
    inc     r13
    dec     rcx
    jmp     .rlp
.emit:
    lea     rsi, [dec_scratch]
    mov     rdx, r12
    call    buf_bytes
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── buf_goto: emit ESC[row;colH  (row/col 1-based, passed in rdi/rsi) ─────────
; Row and col are saved on the stack so called helpers can't corrupt them.
buf_goto:
    push    rdi                 ; row (1-based) at [rsp+8] after push rsi
    push    rsi                 ; col (1-based) at [rsp]
    mov     al, 0x1b
    call    buf_byte
    mov     al, '['
    call    buf_byte
    mov     rax, [rsp + 8]      ; reload row from stack
    call    buf_dec
    mov     al, ';'
    call    buf_byte
    mov     rax, [rsp]          ; reload col from stack
    call    buf_dec
    mov     al, 'H'
    call    buf_byte
    pop     rsi
    pop     rdi
    ret

; ── random ────────────────────────────────────────────────────────────────────
refill_rand:
    push    rdi
    push    rsi
    push    rdx
    xor     rax, rax
    mov     rdi, [urand_fd]
    lea     rsi, [randbuf]
    mov     rdx, RAND_BUF
    syscall
    mov     qword [rand_pos], 0
    pop     rdx
    pop     rsi
    pop     rdi
    ret

; → al = random byte 0–255
rand_byte:
    mov     rax, [rand_pos]
    cmp     rax, RAND_BUF
    jb      .ok
    call    refill_rand
    mov     rax, [rand_pos]
.ok:
    movzx   eax, byte [randbuf + rax]
    inc     qword [rand_pos]
    ret

; → rax = random value in [rdi, rsi] inclusive
rand_range:
    push    rdi
    push    rsi
    sub     rsi, rdi
    inc     rsi                 ; range width
    call    rand_byte
    movzx   eax, al
    xor     rdx, rdx
    div     rsi                 ; rdx = rax % width
    pop     rsi
    pop     rdi
    lea     rax, [rdx + rdi]
    ret

; ── column management ─────────────────────────────────────────────────────────
; Initialise column index rdi with random length/speed, head = 0.
init_column:
    push    rbx
    mov     rbx, rdi
    mov     qword [col_head  + rbx*8], 0
    mov     rdi, MIN_LEN
    mov     rsi, MAX_LEN
    call    rand_range
    mov     [col_len   + rbx*8], rax
    mov     rdi, MIN_SPEED
    mov     rsi, MAX_SPEED
    call    rand_range
    mov     [col_speed + rbx*8], rax
    mov     [col_timer + rbx*8], rax
    mov     byte [col_active + rbx], 1
    pop     rbx
    ret

; → al = random printable char from the matrix charset
random_char:
    mov     rdi, 0
    mov     rsi, chars_len - 1
    call    rand_range
    movzx   eax, byte [chars + rax]
    ret

; ── draw_cell: cursor to (r12 row, rbx col) then write a char ────────────────
; Color escape must be emitted by the caller before calling draw_cell.
draw_cell:
    push    rdi
    push    rsi
    lea     rdi, [r12 + 1]      ; 1-based row
    lea     rsi, [rbx + 1]      ; 1-based col
    call    buf_goto
    call    random_char
    call    buf_byte
    pop     rsi
    pop     rdi
    ret

; ── erase_cell: overwrite (r12 row, rbx col) with a blank ───────────────────
erase_cell:
    push    rdi
    push    rsi
    lea     rdi, [r12 + 1]
    lea     rsi, [rbx + 1]
    call    buf_goto
    lea     rsi, [clr_erase]    ; ESC[0m + space
    mov     rdx, clr_erase_len
    call    buf_bytes
    pop     rsi
    pop     rdi
    ret

; ── update_and_draw: advance every column and render ─────────────────────────
;
; Register conventions (caller-saved across this function):
;   rbx = current column index
;   r12 = scratch row value
;   r13 = rows count / trail_start (reused)
;   r14 = col_len or trail_start
;   r15 = cols count / trail_end (reused)
update_and_draw:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15

    mov     r15, [cols]
    xor     rbx, rbx

.col_loop:
    cmp     rbx, r15
    jge     .col_done

    cmp     byte [col_active + rbx], 0
    je      .next_col

    ; tick timer
    dec     qword [col_timer + rbx*8]
    jnz     .redraw_head        ; not time to move

    ; ── advance head ──────────────────────────────────────────────────────────
    mov     rax, [col_speed + rbx*8]
    mov     [col_timer + rbx*8], rax

    inc     qword [col_head + rbx*8]
    mov     r12, [col_head + rbx*8]   ; r12  = head counter
    mov     r14, [col_len  + rbx*8]   ; r14  = trail length
    mov     r13, [rows]             ; r13  = total rows

    ; tail position (0-based) = r12 - r14 - 1
    ; when tail >= rows the whole drop has scrolled off
    mov     rax, r12
    sub     rax, r14
    dec     rax
    cmp     rax, r13
    jge     .deactivate

    ; erase trailing cell when it has scrolled on-screen
    mov     rax, r12
    sub     rax, r14
    dec     rax                 ; tail row (0-based)
    test    rax, rax
    js      .skip_erase
    cmp     rax, r13
    jge     .skip_erase
    push    r12
    mov     r12, rax
    call    erase_cell
    pop     r12
.skip_erase:

    ; draw head char at row (r12 - 1) in bright white
    mov     rax, r12
    dec     rax
    cmp     rax, 0
    js      .draw_trail
    cmp     rax, r13
    jge     .draw_trail
    push    r12
    mov     r12, rax
    lea     rsi, [clr_head]
    mov     rdx, clr_head_len
    call    buf_bytes
    call    draw_cell
    pop     r12

.draw_trail:
    ; bright green at row (r12 - 2)
    mov     rax, r12
    sub     rax, 2
    cmp     rax, 0
    js      .draw_normal
    cmp     rax, r13
    jge     .draw_normal
    push    r12
    mov     r12, rax
    lea     rsi, [clr_bright]
    mov     rdx, clr_bright_len
    call    buf_bytes
    call    draw_cell
    pop     r12

.draw_normal:
    ; trail rows from max(0, r12-r14) up to r12-3 (exclusive)
    mov     rax, r12
    sub     rax, r14            ; trail start (may be negative)
    test    rax, rax
    jns     .ts_ok
    xor     rax, rax
.ts_ok:
    mov     r14, rax            ; r14 = trail_start (0-based)

    mov     rax, r12
    sub     rax, 3              ; trail end (exclusive)
    test    rax, rax
    js      .trail_skip         ; nothing to draw
    cmp     r14, rax
    jge     .trail_skip

    push    r12
    push    r15
    mov     r15, rax            ; r15 = trail_end
    mov     r12, r14            ; r12 = current trail row

.tloop:
    cmp     r12, r15
    jge     .tloop_done
    cmp     r12, 0
    js      .tinc
    cmp     r12, [rows]
    jge     .tloop_done

    ; lower half of trail → dim; upper half → normal green
    mov     rcx, [col_len + rbx*8]
    shr     rcx, 1
    mov     rdx, r12
    sub     rdx, r14
    cmp     rdx, rcx
    jl      .tdark
    lea     rsi, [clr_normal]
    mov     rdx, clr_normal_len
    call    buf_bytes
    jmp     .tcell
.tdark:
    lea     rsi, [clr_dark]
    mov     rdx, clr_dark_len
    call    buf_bytes
.tcell:
    call    draw_cell
.tinc:
    inc     r12
    jmp     .tloop
.tloop_done:
    pop     r15
    pop     r12

.trail_skip:
    jmp     .next_col

    ; ── redraw head only (flicker) ────────────────────────────────────────────
.redraw_head:
    mov     r12, [col_head + rbx*8]
    dec     r12
    cmp     r12, 0
    js      .next_col
    cmp     r12, [rows]
    jge     .next_col
    lea     rsi, [clr_head]
    mov     rdx, clr_head_len
    call    buf_bytes
    call    draw_cell
    jmp     .next_col

.deactivate:
    mov     byte [col_active + rbx], 0

.next_col:
    inc     rbx
    jmp     .col_loop

.col_done:
    ; randomly activate idle columns (~3% chance per frame)
    mov     r15, [cols]
    xor     rbx, rbx
.wake_loop:
    cmp     rbx, r15
    jge     .wake_done
    cmp     byte [col_active + rbx], 0
    jne     .wake_next
    call    rand_byte
    cmp     al, 7
    jge     .wake_next
    mov     rdi, rbx
    call    init_column
.wake_next:
    inc     rbx
    jmp     .wake_loop
.wake_done:

    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── _start ────────────────────────────────────────────────────────────────────
_start:
    ; open /dev/urandom
    mov     rax, 2
    lea     rdi, [dev_urandom]
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .err
    mov     [urand_fd], rax

    ; get terminal size (falls back to 24×80 if not a tty)
    mov     rax, 16
    mov     rdi, 1
    mov     rsi, TIOCGWINSZ
    lea     rdx, [ws_row]
    syscall

    movzx   rax, word [ws_row]
    test    rax, rax
    jnz     .rows_ok
    mov     rax, 24
.rows_ok:
    mov     [rows], rax

    movzx   rax, word [ws_col]
    test    rax, rax
    jnz     .cols_ok
    mov     rax, 80
.cols_ok:
    cmp     rax, MAX_COLS
    jbe     .cols_ok2
    mov     rax, MAX_COLS
.cols_ok2:
    mov     [cols], rax

    ; install SIGINT + SIGTERM → sig_handler
    lea     rax, [sig_handler]
    mov     [sigact], rax
    mov     qword [sigact + 8], SA_RESTORER
    lea     rax, [sig_restorer]
    mov     [sigact + 16], rax
    mov     qword [sigact + 24], 0

    mov     rax, 13             ; rt_sigaction
    mov     rdi, 2              ; SIGINT
    lea     rsi, [sigact]
    xor     rdx, rdx
    mov     r10, 8
    syscall

    mov     rax, 13
    mov     rdi, 15             ; SIGTERM
    lea     rsi, [sigact]
    xor     rdx, rdx
    mov     r10, 8
    syscall

    ; hide cursor and clear screen
    mov     rax, 1
    mov     rdi, 1
    lea     rsi, [seq_hide]
    mov     rdx, seq_hide_len
    syscall
    mov     rax, 1
    mov     rdi, 1
    lea     rsi, [seq_cls]
    mov     rdx, seq_cls_len
    syscall

    ; pre-fill random buffer so seeds are genuinely random
    call    refill_rand

    ; seed half the columns with staggered start rows
    mov     r15, [cols]
    xor     rbx, rbx
.seed:
    cmp     rbx, r15
    jge     .seed_done
    call    rand_byte
    cmp     al, 128
    jge     .seed_skip
    mov     rdi, rbx
    call    init_column
    ; choose a random starting row so columns don't all begin at the top
    call    rand_byte
    movzx   eax, al
    xor     rdx, rdx
    div     qword [rows]        ; rdx = rax % rows
    inc     rdx                 ; col_head = rdx+1 so drawn head row = rdx
    mov     [col_head + rbx*8], rdx
.seed_skip:
    inc     rbx
    jmp     .seed
.seed_done:

    ; main loop
.loop:
    call    update_and_draw
    call    flush

    mov     rax, 35             ; nanosleep
    lea     rdi, [tv_sec]
    xor     rsi, rsi
    syscall

    jmp     .loop

.err:
    mov     rax, 60
    mov     rdi, 1
    syscall
