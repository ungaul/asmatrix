; Matrix rain – pure x86-64 Linux NASM assembly
; Usage: ./matrix [--density 1-9] [--speed 1-9] [--color SPEC]
;   SPEC = name (green|red|blue|cyan|yellow|white) | hex (#RRGGBB) | ANSI 0-255

DEFAULT REL
global _start

MAX_COLS    equ 512
BUF_SIZE    equ 65536
RAND_BUF    equ 256
TIOCGWINSZ  equ 0x5413
SA_RESTORER equ 0x04000000

; terminal raw-mode / non-blocking input
TCGETS      equ 0x5401
TCSETS      equ 0x5402
F_SETFL     equ 4
O_NONBLOCK  equ 0x800
ICANON      equ 0x0002
ECHO        equ 0x0008

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
    sigact      resb 32
    orig_termios resb 64
    raw_termios  resb 64
    input_buf    resb 16

    ; runtime config (set to defaults in _start, then overridden by CLI args)
    cfg_density     resb 1      ; 0-8  (user input 1-9, stored as index)
    cfg_speed       resb 1      ; 0-8
    cfg_color_mode  resb 1      ; 0 = named (table idx), 1 = truecolor RGB, 2 = ANSI-256
    cfg_color_a     resb 1      ; named: color_schemes index | RGB: red | ANSI-256: index
    cfg_color_b     resb 1      ; RGB: green (unused for named / ANSI-256)
    cfg_color_c     resb 1      ; RGB: blue  (unused for named / ANSI-256)

    ; derived from config by apply_config
    seed_thresh     resb 1      ; rand_byte < thresh → seed column
    wake_thresh     resb 1      ; rand_byte < thresh → wake idle column
    g_min_speed     resb 1      ; drop: min frames-per-step
    g_max_speed     resb 1
    g_min_len       resb 1      ; drop: min trail length
    g_max_len       resb 1

    ; generated ANSI sequences for the active color: bright(0)/normal(1)/dark(2),
    ; each up to 32 bytes (longest possible is "\x1b[1;38;2;255;255;255m" = 21 bytes)
    scheme_seq      resb 96
    scheme_seq_len  resq 3

section .data
    dev_urandom     db "/dev/urandom", 0

    seq_hide        db 0x1b, "[?25l"
    seq_hide_len    equ $ - seq_hide
    seq_show        db 0x1b, "[0m", 0x1b, "[?25h", 0x0a
    seq_show_len    equ $ - seq_show
    seq_cls         db 0x1b, "[2J", 0x1b, "[H"
    seq_cls_len     equ $ - seq_cls

    ; head is always bright white regardless of color scheme
    clr_head        db 0x1b, "[1;38;2;255;255;255m"
    clr_head_len    equ $ - clr_head
    clr_erase       db 0x1b, "[0m "
    clr_erase_len   equ $ - clr_erase

    ; ── named color schemes ───────────────────────────────────────────────────
    ; Each = 3 × 7-byte indexed-ANSI sequences (bright, normal, dark). Using
    ; indexed colors (not truecolor RGB) here is deliberate: it lets the
    ; terminal's own palette/theme render the bold/normal/dim variants, which
    ; gives that familiar muted, low-contrast trail fade — exactly how this
    ; looked before automatic color support was added.
    color_schemes:
    db 0x1b,"[1;32m", 0x1b,"[0;32m", 0x1b,"[2;32m"  ; 0 green  (default)
    db 0x1b,"[1;31m", 0x1b,"[0;31m", 0x1b,"[2;31m"  ; 1 red
    db 0x1b,"[1;34m", 0x1b,"[0;34m", 0x1b,"[2;34m"  ; 2 blue
    db 0x1b,"[1;36m", 0x1b,"[0;36m", 0x1b,"[2;36m"  ; 3 cyan
    db 0x1b,"[1;33m", 0x1b,"[0;33m", 0x1b,"[2;33m"  ; 4 yellow
    db 0x1b,"[0;97m", 0x1b,"[0;37m", 0x1b,"[2;37m"  ; 5 white
    SCHEME_SZ equ 21            ; bytes per scheme (3 × 7-byte sequences)

    ; ── density tables (index 0=density1 … 8=density9) ───────────────────────
    density_seed_tbl  db   4,  8, 16, 22, 30, 42, 60, 90, 128
    density_wake_tbl  db   1,  1,  2,  3,  4,  6,  9, 15,  28

    ; ── speed tables ──────────────────────────────────────────────────────────
    ; Frame delay in nanoseconds (speed 1=slow … 9=fast)
    speed_nsec_tbl  dq  90000000, 70000000, 55000000, 42000000, 33000000, \
                        24000000, 16000000, 10000000,  6000000
    ; Drop advance: frames-per-step (higher = slower drop)
    drop_min_tbl    db  4, 3, 3, 2, 2, 2, 1, 1, 1
    drop_max_tbl    db  8, 7, 6, 5, 4, 4, 3, 2, 2
    ; Drop trail length
    drop_len_min_tbl db  5,  5,  6,  6,  6,  8,  8, 10, 12
    drop_len_max_tbl db 16, 18, 20, 22, 24, 26, 28, 30, 32

    ; nanosleep timespec (tv_nsec overwritten by apply_config)
    tv_sec  dq 0
    tv_nsec dq 33000000

    chars   db "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            db "0123456789@#$%^&*|/<>[]{}:;"
    chars_len equ $ - chars

    err_prefix      db "matrix: unknown option: "
    err_prefix_len  equ $ - err_prefix
    newline         db 0x0a

    help_text:
    db "Usage: matrix [--density 1-9] [--speed 1-9] [--color SPEC]", 0x0a
    db 0x0a
    db "Options:", 0x0a
    db "  --density 1-9   Column density   (1=sparse ... 9=dense,  default 5)", 0x0a
    db "  --speed 1-9     Animation speed  (1=slow   ... 9=fast,   default 7)", 0x0a
    db "  --color SPEC    Color: name, hex (#RRGGBB), or ANSI 0-255  (default: green)", 0x0a
    db "                  Names: green  red  blue  cyan  yellow  white", 0x0a
    db "  --help          Show this message", 0x0a
    db 0x0a
    db "While running: Up/Down arrows adjust speed, Ctrl+C quits.", 0x0a
    help_text_len equ $ - help_text

section .text

; ── signal handler ────────────────────────────────────────────────────────────
sig_handler:
    ; restore original terminal settings (echo / canonical mode)
    mov     rax, 16             ; ioctl
    mov     rdi, 0              ; stdin
    mov     rsi, TCSETS
    lea     rdx, [orig_termios]
    syscall

    ; clear the screen so the rain doesn't linger after we quit
    mov     rax, 1
    mov     rdi, 1
    lea     rsi, [seq_cls]
    mov     rdx, seq_cls_len
    syscall

    mov     rax, 1
    mov     rdi, 1
    lea     rsi, [seq_show]
    mov     rdx, seq_show_len
    syscall
    xor     rdi, rdi
    mov     rax, 60
    syscall

sig_restorer:
    mov     rax, 15
    syscall

; ── flush ─────────────────────────────────────────────────────────────────────
flush:
    mov     rdx, [wbuf_pos]
    test    rdx, rdx
    jz      .done
    mov     rax, 1
    mov     rdi, 1
    lea     rsi, [wbuf]
    syscall
    mov     qword [wbuf_pos], 0
.done:
    ret

; ── buf_byte ──────────────────────────────────────────────────────────────────
buf_byte:
    mov     rcx, [wbuf_pos]
    cmp     rcx, BUF_SIZE - 64
    jb      .store
    push    rax
    call    flush
    pop     rax
    mov     rcx, [wbuf_pos]
.store:
    mov     [wbuf + rcx], al
    inc     rcx
    mov     [wbuf_pos], rcx
    ret

; ── buf_bytes: append mem[rsi..rsi+rdx) ──────────────────────────────────────
buf_bytes:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rsi
    mov     r12, rdx
    xor     r13, r13
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

; ── buf_dec: append decimal rax ───────────────────────────────────────────────
buf_dec:
    push    rbx
    push    r12
    push    r13
    lea     rbx, [dec_scratch]
    xor     r12, r12
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

; ── buf_goto: emit ESC[rdi;rsiH ──────────────────────────────────────────────
buf_goto:
    push    rdi
    push    rsi
    mov     al, 0x1b
    call    buf_byte
    mov     al, '['
    call    buf_byte
    mov     rax, [rsp + 8]      ; row (reload from stack; called helpers may clobber rdi)
    call    buf_dec
    mov     al, ';'
    call    buf_byte
    mov     rax, [rsp]          ; col
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

rand_range:
    push    rdi
    push    rsi
    sub     rsi, rdi
    inc     rsi
    call    rand_byte
    movzx   eax, al
    xor     rdx, rdx
    div     rsi
    pop     rsi
    pop     rdi
    lea     rax, [rdx + rdi]
    ret

; ── column ────────────────────────────────────────────────────────────────────
init_column:
    push    rbx
    mov     rbx, rdi
    mov     qword [col_head + rbx*8], 0
    movzx   rdi, byte [g_min_len]
    movzx   rsi, byte [g_max_len]
    call    rand_range
    mov     [col_len   + rbx*8], rax
    movzx   rdi, byte [g_min_speed]
    movzx   rsi, byte [g_max_speed]
    call    rand_range
    mov     [col_speed + rbx*8], rax
    mov     [col_timer + rbx*8], rax
    mov     byte [col_active + rbx], 1
    pop     rbx
    ret

random_char:
    mov     rdi, 0
    mov     rsi, chars_len - 1
    call    rand_range
    movzx   eax, byte [chars + rax]
    ret

; ── draw / erase ──────────────────────────────────────────────────────────────
draw_cell:
    push    rdi
    push    rsi
    lea     rdi, [r12 + 1]
    lea     rsi, [rbx + 1]
    call    buf_goto
    call    random_char
    call    buf_byte
    pop     rsi
    pop     rdi
    ret

erase_cell:
    push    rdi
    push    rsi
    lea     rdi, [r12 + 1]
    lea     rsi, [rbx + 1]
    call    buf_goto
    lea     rsi, [clr_erase]
    mov     rdx, clr_erase_len
    call    buf_bytes
    pop     rsi
    pop     rdi
    ret

; ── update_and_draw ───────────────────────────────────────────────────────────
; Each advance touches at most 5 cells: new head, 3 trail transitions, erase tail.
; Trail cells are written once; only the head redraws every frame (flicker).
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

    dec     qword [col_timer + rbx*8]
    jnz     .redraw_head

    ; ── advance head ──────────────────────────────────────────────────────────
    mov     rax, [col_speed + rbx*8]
    mov     [col_timer + rbx*8], rax

    inc     qword [col_head + rbx*8]
    mov     r12, [col_head + rbx*8]
    mov     r14, [col_len  + rbx*8]
    mov     r13, [rows]

    ; deactivate when tail has fully left the screen
    mov     rax, r12
    sub     rax, r14
    dec     rax
    cmp     rax, r13
    jge     .deactivate

    ; erase tail cell
    test    rax, rax
    js      .skip_erase
    cmp     rax, r13
    jge     .skip_erase
    push    r12
    mov     r12, rax
    call    erase_cell
    pop     r12
.skip_erase:

%macro draw_row 2   ; %1=offset from r12, %2=brightness level 0/1/2 (bright/normal/dark, or -1 for head)
    mov     rax, r12
    sub     rax, %1
    cmp     rax, 0
    js      %%skip
    cmp     rax, r13
    jge     %%skip
    push    r12
    mov     r12, rax
%if %2 < 0
    lea     rsi, [clr_head]
    mov     rdx, clr_head_len
%else
    lea     rsi, [scheme_seq + (%2 * 32)]
    mov     rdx, [scheme_seq_len + (%2 * 8)]
%endif
    call    buf_bytes
    call    draw_cell
    pop     r12
%%skip:
%endmacro

    draw_row 1, -1   ; head: bright white
    draw_row 2,  0   ; bright
    draw_row 3,  1   ; normal
    draw_row 4,  2   ; dark

    jmp     .next_col

    ; ── redraw head only (flicker, no trail update) ───────────────────────────
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
    ; randomly wake idle columns
    mov     r15, [cols]
    xor     rbx, rbx
.wake_loop:
    cmp     rbx, r15
    jge     .wake_done
    cmp     byte [col_active + rbx], 0
    jne     .wake_next
    call    rand_byte
    movzx   ecx, byte [wake_thresh]
    cmp     al, cl
    jae     .wake_next
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

; ── read_input ────────────────────────────────────────────────────────────────
; Drains pending stdin (non-blocking, terminal in raw/no-echo mode) and reacts
; to arrow keys: Up (ESC [ A) speeds the animation up, Down (ESC [ B) slows it
; down. Any other key is silently discarded — nothing gets echoed to the tty.
; Ctrl+C still raises SIGINT (ISIG stays enabled) and is handled by sig_handler.
read_input:
    push    rbx
    push    r12
    push    r13
    xor     rax, rax            ; sys_read
    xor     rdi, rdi            ; fd 0 (stdin)
    lea     rsi, [input_buf]
    mov     rdx, 15
    syscall
    test    rax, rax
    jle     .done               ; no data available (EAGAIN) or error
    mov     r12, rax            ; bytes read
    xor     rbx, rbx            ; scan index
.scan:
    cmp     rbx, r12
    jge     .done
    movzx   eax, byte [input_buf + rbx]
    cmp     al, 0x1b
    jne     .next
    lea     r13, [rbx + 2]
    cmp     r13, r12
    jg      .next               ; not enough bytes for a full escape sequence
    cmp     byte [input_buf + rbx + 1], '['
    jne     .next
    movzx   eax, byte [input_buf + rbx + 2]
    cmp     al, 'A'
    je      .speed_up
    cmp     al, 'B'
    je      .speed_down
    jmp     .next
.speed_up:
    cmp     byte [cfg_speed], 8
    jge     .skip_seq
    inc     byte [cfg_speed]
    call    apply_config
    jmp     .skip_seq
.speed_down:
    cmp     byte [cfg_speed], 0
    jle     .skip_seq
    dec     byte [cfg_speed]
    call    apply_config
.skip_seq:
    add     rbx, 3
    jmp     .scan
.next:
    inc     rbx
    jmp     .scan
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ── hex_val: ASCII hex digit (al) → nibble 0-15, or 0xFF if not a hex digit ──
hex_val:
    cmp     al, '0'
    jb      .bad
    cmp     al, '9'
    ja      .alpha
    sub     al, '0'
    ret
.alpha:
    cmp     al, 'A'
    jb      .bad
    cmp     al, 'F'
    jbe     .upper
    cmp     al, 'a'
    jb      .bad
    cmp     al, 'f'
    ja      .bad
    sub     al, 'a' - 10
    ret
.upper:
    sub     al, 'A' - 10
    ret
.bad:
    mov     al, 0xFF
    ret

; ── dec_to_buf: write decimal ASCII for rax (0-255) at [rdi] ─────────────────
; → rax: number of bytes written (1-3, no leading zeros)
dec_to_buf:
    push    rbx
    push    rcx
    push    rdx
    push    r9
    push    r10
    push    r11
    mov     rbx, rdi
    xor     rcx, rcx
    test    rax, rax
    jnz     .cvt
    mov     byte [rbx], '0'
    mov     rcx, 1
    jmp     .rev_done
.cvt:
.dloop:
    test    rax, rax
    jz      .rev
    xor     rdx, rdx
    mov     r9, 10
    div     r9
    add     dl, '0'
    mov     [rbx + rcx], dl
    inc     rcx
    jmp     .dloop
.rev:
    xor     r10, r10
    mov     r11, rcx
    dec     r11
.rlp:
    cmp     r10, r11
    jge     .rev_done
    movzx   eax, byte [rbx + r10]
    movzx   edx, byte [rbx + r11]
    mov     [rbx + r10], dl
    mov     [rbx + r11], al
    inc     r10
    dec     r11
    jmp     .rlp
.rev_done:
    mov     rax, rcx
    pop     r11
    pop     r10
    pop     r9
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; ── scale_component: dim a 0-255 channel for the normal/dark trail levels ────
; eax = channel value, esi = level (0=normal ≈62%, 1=bright =100%, 2=dark ≈25%)
; → eax = scaled value
; Truecolor gradients can't rely on the terminal's bold/dim handling — many
; terminals render SGR 1/2 with truecolor RGB as same-color-different-weight,
; which flattens the bright/normal/dark trail into one flat shade. Scaling the
; RGB ourselves guarantees the fade regardless of terminal.
scale_component:
    cmp     esi, 1
    je      .bright
    cmp     esi, 2
    je      .dark
    imul    eax, eax, 5         ; normal ≈ value * 5/8
    shr     eax, 3
    ret
.dark:
    shr     eax, 2              ; dark ≈ value / 4
    ret
.bright:
    ret

; ── emit_color_seq: build one ANSI SGR sequence at [rdi] ──────────────────────
; Only used for explicit hex / ANSI-256 color specs (cfg_color_mode 1 or 2);
; named colors are handled directly from the static color_schemes table in
; apply_config, so the terminal's own palette can render them.
; rdi = dest buffer, rsi = brightness level (0=normal, 1=bright, 2=dark)
; Reads cfg_color_mode/cfg_color_a/b/c.
;   mode 1 truecolor: "ESC[0;38;2;R;G;Bm" with R/G/B scaled per level (the
;              fade lives in the color itself, so the leading attr stays plain)
;   mode 2 ANSI-256:  "ESC[<level>;38;5;Nm" — palette brightness can't be
;              scaled, so fall back to varying bold/normal/dim like before
; → rax: length written
emit_color_seq:
    push    rbx
    push    rcx
    push    rdx
    push    r12
    push    r13
    mov     r12, rdi            ; r12 = sequence start (for length calc)
    mov     rbx, rdi            ; rbx = write cursor
    mov     r13, rsi            ; r13 = level (0/1/2)

    mov     byte [rbx], 0x1b
    mov     byte [rbx + 1], '['
    add     rbx, 2

    cmp     byte [cfg_color_mode], 2
    je      .attr_indexed
    mov     byte [rbx], '0'     ; truecolor: gradient comes from scaled RGB
    jmp     .attr_done
.attr_indexed:
    mov     al, r13b
    add     al, '0'
    mov     [rbx], al
.attr_done:
    inc     rbx
    mov     byte [rbx], ';'
    inc     rbx
    mov     byte [rbx], '3'
    mov     byte [rbx + 1], '8'
    mov     byte [rbx + 2], ';'
    add     rbx, 3

    cmp     byte [cfg_color_mode], 2
    je      .ansi256

    ; truecolor: "2;R;G;Bm" with each channel scaled to this brightness level
    mov     byte [rbx], '2'
    mov     byte [rbx + 1], ';'
    add     rbx, 2

    movzx   eax, byte [cfg_color_a]
    mov     esi, r13d
    call    scale_component
    mov     rdi, rbx
    call    dec_to_buf
    add     rbx, rax
    mov     byte [rbx], ';'
    inc     rbx

    movzx   eax, byte [cfg_color_b]
    mov     esi, r13d
    call    scale_component
    mov     rdi, rbx
    call    dec_to_buf
    add     rbx, rax
    mov     byte [rbx], ';'
    inc     rbx

    movzx   eax, byte [cfg_color_c]
    mov     esi, r13d
    call    scale_component
    mov     rdi, rbx
    call    dec_to_buf
    add     rbx, rax
    jmp     .finish

.ansi256:
    ; indexed: "5;Nm"
    mov     byte [rbx], '5'
    mov     byte [rbx + 1], ';'
    add     rbx, 2
    movzx   rax, byte [cfg_color_a]
    mov     rdi, rbx
    call    dec_to_buf
    add     rbx, rax

.finish:
    mov     byte [rbx], 'm'
    inc     rbx
    mov     rax, rbx
    sub     rax, r12
    pop     r13
    pop     r12
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; ── parse_color_value ─────────────────────────────────────────────────────────
; rsi = pointer to color spec string (null-terminated)
; Accepts: "#RRGGBB" / "RRGGBB" hex, a 0-255 ANSI-256 decimal code, or one of
; the known color names (matched by first letter, as before).
; On success sets cfg_color_mode/a/b/c and returns rax = 0; returns rax = 1
; if the spec isn't recognised (cfg_color_* left untouched).
parse_color_value:
    push    rbx
    push    rcx
    push    rdx
    push    r12

    mov     rbx, rsi
    cmp     byte [rbx], '#'
    jne     .try_hex
    inc     rbx

.try_hex:
    xor     rcx, rcx
.hexcheck:
    cmp     rcx, 6
    jge     .hexcheck_term
    movzx   eax, byte [rbx + rcx]
    call    hex_val
    cmp     al, 0xFF
    je      .not_hex
    inc     rcx
    jmp     .hexcheck
.hexcheck_term:
    cmp     byte [rbx + 6], 0
    jne     .not_hex

    ; valid 6-digit hex → RGB
    movzx   eax, byte [rbx + 0]
    call    hex_val
    mov     r12b, al
    shl     r12b, 4
    movzx   eax, byte [rbx + 1]
    call    hex_val
    or      r12b, al
    mov     [cfg_color_a], r12b
    movzx   eax, byte [rbx + 2]
    call    hex_val
    mov     r12b, al
    shl     r12b, 4
    movzx   eax, byte [rbx + 3]
    call    hex_val
    or      r12b, al
    mov     [cfg_color_b], r12b
    movzx   eax, byte [rbx + 4]
    call    hex_val
    mov     r12b, al
    shl     r12b, 4
    movzx   eax, byte [rbx + 5]
    call    hex_val
    or      r12b, al
    mov     [cfg_color_c], r12b
    mov     byte [cfg_color_mode], 1    ; 1 = truecolor RGB
    xor     eax, eax
    jmp     .done

.not_hex:
    cmp     byte [rsi], '#'
    je      .fail               ; "#..." that isn't valid 6-digit hex → reject

    ; decimal ANSI-256 code (1-3 digits, value 0-255)
    xor     rcx, rcx
    xor     r12, r12
.numcheck:
    movzx   eax, byte [rbx + rcx]
    test    al, al
    jz      .numcheck_done
    cmp     al, '0'
    jb      .not_numeric
    cmp     al, '9'
    ja      .not_numeric
    cmp     rcx, 3
    jge     .not_numeric
    imul    r12, r12, 10
    movzx   eax, al
    sub     eax, '0'
    add     r12, rax
    inc     rcx
    jmp     .numcheck
.numcheck_done:
    test    rcx, rcx
    jz      .not_numeric
    cmp     r12, 255
    ja      .not_numeric
    mov     byte [cfg_color_a], r12b
    mov     byte [cfg_color_mode], 2    ; 2 = ANSI-256 indexed
    xor     eax, eax
    jmp     .done

.not_numeric:
    ; known color names, matched by first letter (kept simple, like before).
    ; These map to indices into color_schemes (mode 0): letting the terminal
    ; render indexed-ANSI bold/normal/dim is what gives that familiar muted
    ; trail fade, themed by whatever palette the user's terminal applies.
    movzx   eax, byte [rbx]
    cmp     al, 'g'
    je      .name_green
    cmp     al, 'r'
    je      .name_red
    cmp     al, 'b'
    je      .name_blue
    cmp     al, 'c'
    je      .name_cyan
    cmp     al, 'y'
    je      .name_yellow
    cmp     al, 'w'
    je      .name_white
    jmp     .fail

.name_green:  mov byte [cfg_color_a], 0
              jmp .name_done
.name_red:    mov byte [cfg_color_a], 1
              jmp .name_done
.name_blue:   mov byte [cfg_color_a], 2
              jmp .name_done
.name_cyan:   mov byte [cfg_color_a], 3
              jmp .name_done
.name_yellow: mov byte [cfg_color_a], 4
              jmp .name_done
.name_white:  mov byte [cfg_color_a], 5
.name_done:
    mov     byte [cfg_color_mode], 0    ; 0 = named (color_schemes table index)
    xor     eax, eax
    jmp     .done

.fail:
    mov     eax, 1

.done:
    pop     r12
    pop     rdx
    pop     rcx
    pop     rbx
    ret

; ── parse_arg ─────────────────────────────────────────────────────────────────
; rdi = arg string (not modified)
; rsi = next arg string, or 0 if this is the last argv entry
;       (used as the value for options like "--speed 9")
; → rax: 0 = handled, 1 = --help, 2 = unrecognised -- option,
;        3 = handled and the value in rsi was consumed too
parse_arg:
    cmp     byte [rdi], '-'
    jne     .ok             ; not a flag at all → ignore
    cmp     byte [rdi + 1], '-'
    jne     .ok
    movzx   eax, byte [rdi + 2]
    cmp     al, 'h'
    je      .help
    cmp     al, 'd'
    je      .density
    cmp     al, 's'
    je      .speed
    cmp     al, 'c'
    je      .color
    jmp     .unknown

.help:
    cmp     byte [rdi + 3], 'e'
    jne     .unknown
    cmp     byte [rdi + 4], 'l'
    jne     .unknown
    cmp     byte [rdi + 5], 'p'
    jne     .unknown
    mov     eax, 1
    ret

.density:
    cmp     byte [rdi +  3], 'e'
    jne     .unknown
    cmp     byte [rdi +  4], 'n'
    jne     .unknown
    cmp     byte [rdi +  5], 's'
    jne     .unknown
    cmp     byte [rdi +  6], 'i'
    jne     .unknown
    cmp     byte [rdi +  7], 't'
    jne     .unknown
    cmp     byte [rdi +  8], 'y'
    jne     .unknown
    cmp     byte [rdi +  9], 0
    jne     .unknown
    test    rsi, rsi
    jz      .unknown
    movzx   eax, byte [rsi]
    sub     al, '1'
    cmp     al, 8
    ja      .unknown
    mov     [cfg_density], al
    jmp     .consumed

.speed:
    cmp     byte [rdi + 3], 'p'
    jne     .unknown
    cmp     byte [rdi + 4], 'e'
    jne     .unknown
    cmp     byte [rdi + 5], 'e'
    jne     .unknown
    cmp     byte [rdi + 6], 'd'
    jne     .unknown
    cmp     byte [rdi + 7], 0
    jne     .unknown
    test    rsi, rsi
    jz      .unknown
    movzx   eax, byte [rsi]
    sub     al, '1'
    cmp     al, 8
    ja      .unknown
    mov     [cfg_speed], al
    jmp     .consumed

.color:
    cmp     byte [rdi + 3], 'o'
    jne     .unknown
    cmp     byte [rdi + 4], 'l'
    jne     .unknown
    cmp     byte [rdi + 5], 'o'
    jne     .unknown
    cmp     byte [rdi + 6], 'r'
    jne     .unknown
    cmp     byte [rdi + 7], 0
    jne     .unknown
    test    rsi, rsi
    jz      .unknown
    call    parse_color_value   ; rsi = color spec string; sets cfg_color_*
    test    rax, rax
    jnz     .unknown            ; not a recognised name / hex / ANSI code
    jmp     .consumed

.consumed:
    mov     eax, 3              ; handled, and the value arg was consumed too
    ret

.ok:
    xor     eax, eax
    ret

.unknown:
    mov     eax, 2
    ret

; ── print_help_exit: write help to stdout, then exit(code in rdi) ─────────────
print_help_exit:
    push    rdi                 ; save exit code
    mov     rax, 1
    mov     rdi, 1
    lea     rsi, [help_text]
    mov     rdx, help_text_len
    syscall
    pop     rdi
    mov     rax, 60
    syscall

; ── print_unknown_arg: "matrix: unknown option: ARG\n" to stderr ─────────────
; rdi = pointer to the unknown arg string
print_unknown_arg:
    push    rdi
    mov     rax, 1
    mov     rdi, 2              ; stderr
    lea     rsi, [err_prefix]
    mov     rdx, err_prefix_len
    syscall
    pop     rsi                 ; arg string
    push    rsi
    ; compute strlen(arg)
    xor     rcx, rcx
.sl: cmp    byte [rsi + rcx], 0
    je      .sl_done
    inc     rcx
    jmp     .sl
.sl_done:
    mov     rdx, rcx
    mov     rax, 1
    mov     rdi, 2
    syscall
    mov     rax, 1
    mov     rdi, 2
    lea     rsi, [newline]
    mov     rdx, 1
    syscall
    pop     rdi                 ; discard saved ptr
    ret

; ── apply_config: translate cfg_* into runtime parameters ────────────────────
apply_config:
    ; density → seed + wake thresholds
    movzx   rax, byte [cfg_density]
    movzx   rcx, byte [density_seed_tbl + rax]
    mov     [seed_thresh], cl
    movzx   rcx, byte [density_wake_tbl + rax]
    mov     [wake_thresh], cl

    ; speed → frame delay + drop speed/length ranges
    movzx   rax, byte [cfg_speed]
    mov     rcx, [speed_nsec_tbl + rax*8]
    mov     [tv_nsec], rcx
    movzx   rcx, byte [drop_min_tbl + rax]
    mov     [g_min_speed], cl
    movzx   rcx, byte [drop_max_tbl + rax]
    mov     [g_max_speed], cl
    movzx   rcx, byte [drop_len_min_tbl + rax]
    mov     [g_min_len], cl
    movzx   rcx, byte [drop_len_max_tbl + rax]
    mov     [g_max_len], cl

    ; color → fill scheme_seq with bright(0)/normal(1)/dark(2) sequences
    cmp     byte [cfg_color_mode], 0
    jne     .color_dynamic

    ; named: copy the matching scheme's 3 × 7-byte sequences from color_schemes
    ; (packed back-to-back) into the 32-byte-aligned scheme_seq slots, so the
    ; terminal's own palette renders the bold/normal/dim trail fade
    movzx   eax, byte [cfg_color_a]
    imul    eax, eax, SCHEME_SZ
    lea     rsi, [color_schemes + rax]

    lea     rdi, [scheme_seq]
    mov     rcx, 7
    rep     movsb               ; bright  (rsi/rdi both auto-advance by 7)

    lea     rdi, [scheme_seq + 32]
    mov     rcx, 7
    rep     movsb               ; normal

    lea     rdi, [scheme_seq + 64]
    mov     rcx, 7
    rep     movsb               ; dark

    mov     qword [scheme_seq_len + 0*8], 7
    mov     qword [scheme_seq_len + 1*8], 7
    mov     qword [scheme_seq_len + 2*8], 7
    jmp     .color_done

.color_dynamic:
    ; hex / ANSI-256: generate bright(1)/normal(0)/dark(2) sequences
    lea     rdi, [scheme_seq]
    mov     rsi, 1
    call    emit_color_seq
    mov     [scheme_seq_len + 0*8], rax

    lea     rdi, [scheme_seq + 32]
    xor     rsi, rsi
    call    emit_color_seq
    mov     [scheme_seq_len + 1*8], rax

    lea     rdi, [scheme_seq + 64]
    mov     rsi, 2
    call    emit_color_seq
    mov     [scheme_seq_len + 2*8], rax

.color_done:
    ret

; ── _start ────────────────────────────────────────────────────────────────────
_start:
    ; save stack pointer to access argc/argv (rsp not touched yet)
    mov     r14, rsp            ; r14 = original stack pointer

    ; open /dev/urandom
    mov     rax, 2
    lea     rdi, [dev_urandom]
    xor     rsi, rsi
    xor     rdx, rdx
    syscall
    test    rax, rax
    js      .err
    mov     [urand_fd], rax

    ; get terminal dimensions
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

    ; set defaults: density 7, speed 5, color green  (indices are 0-based)
    mov     byte [cfg_density], 4
    mov     byte [cfg_speed],   6
    mov     byte [cfg_color_mode], 0    ; 0 = named (color_schemes table index)
    mov     byte [cfg_color_a], 0       ; index 0 = green

    ; parse argv
    mov     r13, [r14]          ; argc
    lea     r15, [r14 + 16]     ; &argv[1]
    dec     r13                 ; number of real args
.arg_loop:
    test    r13, r13
    jz      .arg_done
    mov     rdi, [r15]
    xor     rsi, rsi            ; rsi = next arg, or 0 if none follows
    cmp     r13, 1
    jle     .no_next_arg
    mov     rsi, [r15 + 8]
.no_next_arg:
    call    parse_arg
    cmp     rax, 1
    je      .do_help
    cmp     rax, 2
    je      .do_unknown
    cmp     rax, 3
    je      .consumed_two
    add     r15, 8
    dec     r13
    jmp     .arg_loop
.consumed_two:
    add     r15, 16
    sub     r13, 2
    jmp     .arg_loop
.do_help:
    xor     rdi, rdi            ; exit code 0
    call    print_help_exit     ; does not return
.do_unknown:
    mov     rdi, [r15]          ; reload arg pointer (parse_arg preserves rdi but be safe)
    call    print_unknown_arg
    xor     rdi, rdi
    mov     rdi, 1              ; exit code 1
    call    print_help_exit     ; does not return
.arg_done:

    call    apply_config

    ; install SIGINT + SIGTERM → sig_handler
    lea     rax, [sig_handler]
    mov     [sigact], rax
    mov     qword [sigact + 8], SA_RESTORER
    lea     rax, [sig_restorer]
    mov     [sigact + 16], rax
    mov     qword [sigact + 24], 0

    mov     rax, 13
    mov     rdi, 2
    lea     rsi, [sigact]
    xor     rdx, rdx
    mov     r10, 8
    syscall

    mov     rax, 13
    mov     rdi, 15
    lea     rsi, [sigact]
    xor     rdx, rdx
    mov     r10, 8
    syscall

    ; ── put the tty into raw mode: no echo, no line buffering ────────────────
    ; (ISIG stays on, so Ctrl+C still raises SIGINT → handled by sig_handler,
    ;  which restores these settings before exiting)
    mov     rax, 16             ; ioctl
    mov     rdi, 0              ; stdin
    mov     rsi, TCGETS
    lea     rdx, [orig_termios]
    syscall

    lea     rsi, [orig_termios]
    lea     rdi, [raw_termios]
    mov     rcx, 36
    rep     movsb

    mov     eax, [raw_termios + 12]     ; c_lflag
    and     eax, ~(ICANON | ECHO)
    mov     [raw_termios + 12], eax

    mov     rax, 16
    mov     rdi, 0
    mov     rsi, TCSETS
    lea     rdx, [raw_termios]
    syscall

    ; make stdin reads non-blocking so the render loop never stalls on input
    mov     rax, 72             ; fcntl
    mov     rdi, 0
    mov     rsi, F_SETFL
    mov     rdx, O_NONBLOCK
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

    call    refill_rand

    ; seed columns
    mov     r15, [cols]
    xor     rbx, rbx
.seed:
    cmp     rbx, r15
    jge     .seed_done
    call    rand_byte
    movzx   ecx, byte [seed_thresh]
    cmp     al, cl
    jae     .seed_skip
    mov     rdi, rbx
    call    init_column
    call    rand_byte
    movzx   eax, al
    xor     rdx, rdx
    div     qword [rows]
    inc     rdx
    mov     [col_head + rbx*8], rdx
.seed_skip:
    inc     rbx
    jmp     .seed
.seed_done:

.loop:
    call    update_and_draw
    call    flush
    call    read_input

    mov     rax, 35
    lea     rdi, [tv_sec]
    xor     rsi, rsi
    syscall

    jmp     .loop

.err:
    mov     rax, 60
    mov     rdi, 1
    syscall
