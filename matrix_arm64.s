.equ MAX_COLS, 512
.equ BUF_SIZE, 65536

.macro LB rd, sym
    adr     x17, \sym
    ldrb    \rd, [x17]
.endm

.macro SB rs, sym
    adr     x17, \sym
    strb    \rs, [x17]
.endm

.section .bss
.balign 8
rows:       .skip 8
cols:       .skip 8
ws:         .skip 8
rng:        .skip 8
wbuf_pos:   .skip 8
tv:         .skip 16
sigact:     .skip 24
orig_termios: .skip 40
raw_termios:  .skip 40
input_buf:  .skip 16
col_head:   .skip MAX_COLS * 2
col_len:    .skip MAX_COLS
col_speed:  .skip MAX_COLS
col_timer:  .skip MAX_COLS
.balign 16
wbuf:       .skip BUF_SIZE

.section .data
cfg_density:    .byte 4
cfg_speed:      .byte 6
cfg_color_mode: .byte 1
cfg_color_a:    .byte 0
cfg_color_b:    .byte 255
cfg_color_c:    .byte 70

seq_hide:   .ascii "\033[?25l"
.equ seq_hide_len, . - seq_hide
seq_cls:    .ascii "\033[2J\033[H"
.equ seq_cls_len, . - seq_cls
seq_show:   .ascii "\033[0m\033[?25h\n"
.equ seq_show_len, . - seq_show

seq_erase:  .byte 4
            .ascii "\033[0m"
clr_pre:    .ascii "\033[0;38;"

seqs:
    .byte 21
    .ascii "\033[0;38;2;255;255;255m"
    .space 2
    .space 48
    .byte 18
    .ascii "\033[0;38;2;70;70;70m"
    .space 5

color_tbl:
    .byte   0, 255,  70, 0x67
    .byte 255,  50,  50, 0x72
    .byte  60, 130, 255, 0x62
    .byte   0, 230, 230, 0x63
    .byte 255, 210,   0, 0x79
    .byte 255, 255, 255, 0x77

density_seed_tbl:   .byte   4,  8, 16, 22, 30, 42, 60, 90, 128
density_wake_tbl:   .byte   1,  1,  2,  3,  4,  6,  9, 15,  28
drop_min_tbl:       .byte  4, 3, 3, 2, 2, 2, 1, 1, 1
drop_max_tbl:       .byte  8, 7, 6, 5, 4, 4, 3, 2, 2
drop_len_min_tbl:   .byte  5,  5,  6,  6,  6,  8,  8, 10, 12
drop_len_max_tbl:   .byte 16, 18, 20, 22, 24, 26, 28, 30, 32
.balign 4
speed_nsec_tbl:     .word 90000000, 70000000, 55000000, 42000000, 33000000
                    .word 24000000, 16000000, 10000000,  6000000

chars:
    .ascii "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    .ascii "0123456789@#$%^&*|/<>[]{}:;"
.equ chars_len, . - chars

o_help:     .asciz "help"
o_density:  .asciz "density"
o_speed:    .asciz "speed"
o_color:    .asciz "color"

err_prefix: .ascii "asmatrix: unknown option: "
.equ err_prefix_len, . - err_prefix

help_text:
    .ascii "Usage: asmatrix [--density 1-9] [--speed 1-9] [--color SPEC]\n"
    .ascii "\n"
    .ascii "Options:\n"
    .ascii "  --density 1-9   Column density   (1=sparse ... 9=dense,  default 5)\n"
    .ascii "  --speed 1-9     Animation speed  (1=slow   ... 9=fast,   default 7)\n"
    .ascii "  --color SPEC    Color: name, hex (#RRGGBB), or ANSI 0-255  (default: green)\n"
    .ascii "                  Names: green  red  blue  cyan  yellow  white\n"
    .ascii "  --help          Show this message\n"
    .ascii "\n"
    .ascii "While running: Up/Down arrows adjust speed, Ctrl+C quits.\n"
.equ help_text_len, . - help_text

.section .text
.global _start

sig_handler:
    mov     x8, #29
    mov     x0, #0
    mov     x1, #0x5402
    adr     x2, orig_termios
    svc     #0
    mov     x8, #64
    mov     x0, #1
    adr     x1, seq_cls
    mov     x2, #(seq_cls_len + seq_show_len)
    svc     #0
    mov     x0, #0
    mov     x8, #93
    svc     #0

flush:
    adr     x16, wbuf_pos
    mov     x8, #64
    mov     x0, #1
    adr     x1, wbuf
    ldr     x2, [x16]
    svc     #0
    str     xzr, [x16]
    ret

dec_to_buf:
    str     x30, [sp, #-16]!
    mov     w1, #10
    udiv    w2, w0, w1
    msub    w3, w2, w1, w0
    cbz     w2, 1f
    str     x3, [sp, #-16]!
    mov     w0, w2
    bl      dec_to_buf
    ldr     x3, [sp], #16
1:
    add     w3, w3, #0x30
    strb    w3, [x4], #1
    ldr     x30, [sp], #16
    ret

rand_byte:
    adr     x17, rng
    ldr     x0, [x17]
    cbnz    x0, 1f
    mrs     x0, cntvct_el0
    orr     x0, x0, #1
1:
    eor     x1, x0, x0, lsl #13
    eor     x1, x1, x1, lsr #7
    eor     x0, x1, x1, lsl #17
    str     x0, [x17]
    lsr     x0, x0, #32
    and     w0, w0, #0xff
    ret

rand_range:
    str     x30, [sp, #-16]!
    sub     w3, w3, w2
    add     w3, w3, #1
    bl      rand_byte
    udiv    w1, w0, w3
    msub    w0, w1, w3, w0
    add     w0, w0, w2
    ldr     x30, [sp], #16
    ret

random_char:
    str     x30, [sp, #-16]!
    bl      rand_byte
    mov     w1, #chars_len
    udiv    w2, w0, w1
    msub    w0, w2, w1, w0
    adr     x1, chars
    ldrb    w0, [x1, x0]
    ldr     x30, [sp], #16
    ret

init_column:
    str     x30, [sp, #-16]!
    LB      w8, cfg_speed
    adr     x14, col_head
    strh    wzr, [x14, x19, lsl #1]
    adr     x15, drop_len_min_tbl
    ldrb    w2, [x15, x8]
    adr     x15, drop_len_max_tbl
    ldrb    w3, [x15, x8]
    bl      rand_range
    adr     x14, col_len
    strb    w0, [x14, x19]
    adr     x15, drop_min_tbl
    ldrb    w2, [x15, x8]
    adr     x15, drop_max_tbl
    ldrb    w3, [x15, x8]
    bl      rand_range
    adr     x14, col_speed
    strb    w0, [x14, x19]
    adr     x14, col_timer
    strb    w0, [x14, x19]
    ldr     x30, [sp], #16
    ret

put_cell:
    adr     x2, rows
    ldr     x2, [x2]
    cmp     x0, x2
    b.hs    9f
    str     x30, [sp, #-16]!
    mov     x9, x0
    mov     x10, x1
    bl      random_char
    mov     w11, w0
    bl      put_raw
    ldr     x30, [sp], #16
9:
    ret

put_raw:
    str     x30, [sp, #-16]!
    adr     x17, wbuf
    adr     x16, wbuf_pos
    ldr     x12, [x16]
    add     x4, x17, x12
    mov     x13, x4
    ldrb    w5, [x10], #1
1:
    cbz     w5, 2f
    ldrb    w6, [x10], #1
    strb    w6, [x4], #1
    sub     w5, w5, #1
    b       1b
2:
    mov     w6, #0x1b
    strb    w6, [x4], #1
    mov     w6, #0x5b
    strb    w6, [x4], #1
    add     w0, w9, #1
    bl      dec_to_buf
    mov     w6, #0x3b
    strb    w6, [x4], #1
    add     w0, w19, #1
    bl      dec_to_buf
    mov     w6, #0x48
    strb    w6, [x4], #1
    strb    w11, [x4], #1
    sub     x4, x4, x13
    adr     x16, wbuf_pos
    ldr     x12, [x16]
    add     x12, x12, x4
    str     x12, [x16]
    ldr     x30, [sp], #16
    ret

update_and_draw:
    stp     x29, x30, [sp, #-48]!
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    LB      w20, cfg_density
    mov     w19, #0
.Lcol:
    adr     x16, wbuf_pos
    ldr     x0, [x16]
    mov     x1, #(BUF_SIZE - 256)
    cmp     x0, x1
    b.lo    .Lnf
    bl      flush
.Lnf:
    adr     x14, col_len
    ldrb    w0, [x14, x19]
    cbnz    w0, .Lactive
    bl      rand_byte
    adr     x15, density_wake_tbl
    ldrb    w1, [x15, x20]
    cmp     w0, w1
    b.hs    .Lnext
    bl      init_column
    b       .Lnext
.Lactive:
    adr     x14, col_timer
    ldrb    w0, [x14, x19]
    sub     w0, w0, #1
    strb    w0, [x14, x19]
    tst     w0, #0xff
    b.ne    .Lredraw
    adr     x14, col_speed
    ldrb    w0, [x14, x19]
    adr     x14, col_timer
    strb    w0, [x14, x19]
    adr     x14, col_head
    ldrh    w21, [x14, x19, lsl #1]
    add     w21, w21, #1
    strh    w21, [x14, x19, lsl #1]
    adr     x14, col_len
    ldrb    w2, [x14, x19]
    sub     x0, x21, x2
    sub     x0, x0, #1
    adr     x16, rows
    ldr     x3, [x16]
    cmp     x0, x3
    b.ge    .Ldeact
    tbnz    x0, #63, .Lnoerase
    mov     x9, x0
    mov     w11, #0x20
    adr     x10, seq_erase
    bl      put_raw
.Lnoerase:
    mov     w22, #1
.Ldr:
    sub     x0, x21, x22
    sub     w1, w22, #1
    add     w1, w1, w1, lsl #1
    lsl     w1, w1, #3
    adr     x2, seqs
    add     x1, x2, x1
    bl      put_cell
    add     w22, w22, #1
    cmp     w22, #4
    b.ls    .Ldr
    b       .Lnext
.Lredraw:
    adr     x14, col_head
    ldrh    w0, [x14, x19, lsl #1]
    sub     w0, w0, #1
    adr     x1, seqs
    bl      put_cell
    b       .Lnext
.Ldeact:
    adr     x14, col_len
    strb    wzr, [x14, x19]
.Lnext:
    add     w19, w19, #1
    adr     x16, cols
    ldr     x0, [x16]
    cmp     w19, w0
    b.lo    .Lcol
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

read_input:
    mov     x8, #63
    mov     x0, #0
    adr     x1, input_buf
    mov     x2, #15
    svc     #0
    cmp     x0, #0
    b.le    9f
    add     x2, x1, x0
    sub     x2, x2, #2
.Lscan:
    cmp     x1, x2
    b.hs    9f
    ldrh    w3, [x1]
    mov     w4, #0x5b1b
    cmp     w3, w4
    b.ne    .Ln
    ldrb    w3, [x1, #2]
    cmp     w3, #0x41
    b.eq    .Lup
    cmp     w3, #0x42
    b.ne    .Ln
    adr     x5, cfg_speed
    ldrb    w6, [x5]
    cbz     w6, .Ls
    sub     w6, w6, #1
    strb    w6, [x5]
    b       .Ls
.Lup:
    adr     x5, cfg_speed
    ldrb    w6, [x5]
    cmp     w6, #8
    b.hs    .Ls
    add     w6, w6, #1
    strb    w6, [x5]
.Ls:
    add     x1, x1, #2
.Ln:
    add     x1, x1, #1
    b       .Lscan
9:
    ret

hex_val:
    sub     w0, w0, #0x30
    and     w0, w0, #0xff
    cmp     w0, #9
    b.ls    2f
    sub     w0, w0, #0x11
    and     w0, w0, #0xff
    cmp     w0, #5
    b.ls    1f
    sub     w0, w0, #0x20
    and     w0, w0, #0xff
    cmp     w0, #5
    b.ls    1f
    mov     w0, #0xff
    ret
1:
    add     w0, w0, #10
2:
    ret

emit_color_seq:
    str     x30, [sp, #-16]!
    mov     x13, x0
    add     x4, x0, #1
    mov     w8, w1
    adr     x5, clr_pre
    ldr     w6, [x5]
    str     w6, [x4]
    ldr     w6, [x5, #3]
    str     w6, [x4, #3]
    add     x4, x4, #7
    LB      w5, cfg_color_mode
    cmp     w5, #2
    b.ne    .Lrgb
    ldrb    w6, [x4, #-5]
    add     w6, w6, w8
    strb    w6, [x4, #-5]
    mov     w6, #0x35
    strb    w6, [x4], #1
    mov     w6, #0x3b
    strb    w6, [x4], #1
    LB      w0, cfg_color_a
    bl      dec_to_buf
    b       .Lfin
.Lrgb:
    mov     w6, #0x32
    strb    w6, [x4], #1
    mov     w6, #0x3b
    strb    w6, [x4], #1
    mov     w9, #0
.Lc:
    adr     x5, cfg_color_a
    ldrb    w0, [x5, x9]
    cbnz    w8, .Lnb
    add     w0, w0, w0, lsl #1
    lsr     w0, w0, #2
.Lnb:
    bl      dec_to_buf
    add     w9, w9, #1
    cmp     w9, #3
    b.eq    .Lfin
    mov     w6, #0x3b
    strb    w6, [x4], #1
    b       .Lc
.Lfin:
    mov     w6, #0x6d
    strb    w6, [x4], #1
    sub     x4, x4, x13
    sub     x4, x4, #1
    strb    w4, [x13]
    ldr     x30, [sp], #16
    ret

parse_color_value:
    str     x30, [sp, #-16]!
    mov     x2, x1
    ldrb    w0, [x2]
    cmp     w0, #0x23
    b.ne    1f
    add     x2, x2, #1
1:
    mov     x3, #0
.Lhp:
    add     x5, x2, x3, lsl #1
    ldrb    w0, [x5]
    bl      hex_val
    cmp     w0, #0xff
    b.eq    .Lnothex
    lsl     w6, w0, #4
    and     w6, w6, #0xff
    ldrb    w0, [x5, #1]
    bl      hex_val
    cmp     w0, #0xff
    b.eq    .Lnothex
    orr     w0, w0, w6
    adr     x7, cfg_color_a
    strb    w0, [x7, x3]
    add     x3, x3, #1
    cmp     x3, #3
    b.lo    .Lhp
    ldrb    w0, [x2, #6]
    cbnz    w0, .Lnothex
    mov     w0, #1
    SB      w0, cfg_color_mode
    b       .Lok
.Lnothex:
    ldrb    w0, [x1]
    cmp     w0, #0x23
    b.eq    .Lfail
    mov     x3, #0
    mov     w4, #0
.Lnl:
    ldrb    w0, [x2, x3]
    cbz     w0, .Lnd
    sub     w0, w0, #0x30
    and     w0, w0, #0xff
    cmp     w0, #9
    b.hi    .Lname
    cmp     x3, #3
    b.hs    .Lname
    mov     w5, #10
    madd    w4, w4, w5, w0
    add     x3, x3, #1
    b       .Lnl
.Lnd:
    cbz     x3, .Lname
    cmp     w4, #255
    b.hi    .Lname
    SB      w4, cfg_color_a
    mov     w0, #2
    SB      w0, cfg_color_mode
    b       .Lok
.Lname:
    ldrb    w0, [x2]
    adr     x5, color_tbl
    mov     w6, #6
.Lnm:
    ldrb    w7, [x5, #3]
    cmp     w0, w7
    b.eq    .Lfound
    add     x5, x5, #4
    subs    w6, w6, #1
    b.ne    .Lnm
.Lfail:
    mov     w0, #1
    ldr     x30, [sp], #16
    ret
.Lfound:
    ldr     w0, [x5]
    lsl     w0, w0, #8
    orr     w0, w0, #1
    adr     x7, cfg_color_mode
    str     w0, [x7]
.Lok:
    mov     w0, #0
    ldr     x30, [sp], #16
    ret

streq:
    mov     x6, x0
1:
    ldrb    w7, [x6], #1
    ldrb    w9, [x5], #1
    cmp     w7, w9
    b.ne    2f
    cbnz    w7, 1b
2:
    ret

parse_arg:
    str     x30, [sp, #-16]!
    ldrh    w2, [x0]
    mov     w3, #0x2d2d
    cmp     w2, w3
    b.ne    .Lplain
    add     x0, x0, #2
    mov     x10, x1
    adr     x5, o_help
    bl      streq
    b.eq    .Lhelp
    adr     x5, o_density
    bl      streq
    b.eq    .Ldensity
    adr     x5, o_speed
    bl      streq
    b.eq    .Lspeed
    adr     x5, o_color
    bl      streq
    b.eq    .Lcolor
.Lunknown:
    mov     w0, #2
    b       .Lret
.Lhelp:
    mov     w0, #1
    b       .Lret
.Ldensity:
    adr     x11, cfg_density
    b       .Lnum
.Lspeed:
    adr     x11, cfg_speed
.Lnum:
    cbz     x10, .Lunknown
    ldrb    w0, [x10]
    sub     w0, w0, #0x31
    and     w0, w0, #0xff
    cmp     w0, #8
    b.hi    .Lunknown
    strb    w0, [x11]
.Lused:
    mov     w0, #3
    b       .Lret
.Lcolor:
    cbz     x10, .Lunknown
    mov     x1, x10
    bl      parse_color_value
    cbnz    w0, .Lunknown
    b       .Lused
.Lplain:
    mov     w0, #0
.Lret:
    ldr     x30, [sp], #16
    ret

print_unknown_arg:
    mov     x9, x0
    mov     x8, #64
    mov     x0, #2
    adr     x1, err_prefix
    mov     x2, #err_prefix_len
    svc     #0
    mov     x1, x9
1:
    ldrb    w2, [x9], #1
    cbnz    w2, 1b
    mov     w2, #10
    strb    w2, [x9, #-1]
    sub     x2, x9, x1
    mov     x0, #2
    mov     x8, #64
    svc     #0
    ret

_start:
    ldr     x20, [sp]
    add     x21, sp, #16
    sub     x20, x20, #1

    mov     x8, #29
    mov     x0, #1
    mov     x1, #0x5413
    adr     x2, ws
    svc     #0
    adr     x2, ws
    ldrh    w0, [x2]
    mov     w1, #24
    cmp     w0, #0
    csel    w0, w1, w0, eq
    adr     x3, rows
    str     x0, [x3]
    ldrh    w0, [x2, #2]
    mov     w1, #80
    cmp     w0, #0
    csel    w0, w1, w0, eq
    mov     w1, #MAX_COLS
    cmp     w0, w1
    csel    w0, w1, w0, hi
    adr     x3, cols
    str     x0, [x3]

.Larg:
    cbz     x20, .Ldone
    ldr     x0, [x21]
    ldr     x1, [x21, #8]
    bl      parse_arg
    cmp     w0, #1
    b.eq    .Ldohelp
    cmp     w0, #2
    b.eq    .Ldounk
    add     x21, x21, #8
    sub     x20, x20, #1
    cmp     w0, #3
    b.ne    .Larg
    add     x21, x21, #8
    sub     x20, x20, #1
    b       .Larg
.Ldounk:
    ldr     x0, [x21]
    bl      print_unknown_arg
    mov     w19, #1
    b       .Lhelpout
.Ldohelp:
    mov     w19, #0
.Lhelpout:
    mov     x8, #64
    mov     x0, #1
    adr     x1, help_text
    mov     x2, #help_text_len
    svc     #0
    mov     x0, x19
    mov     x8, #93
    svc     #0
.Ldone:

    adr     x0, seqs
    add     x0, x0, #24
    mov     w1, #1
    bl      emit_color_seq
    adr     x0, seqs
    add     x0, x0, #48
    mov     w1, #0
    bl      emit_color_seq

    mov     x8, #29
    mov     x0, #0
    mov     x1, #0x5401
    adr     x2, orig_termios
    svc     #0
    adr     x1, orig_termios
    adr     x2, raw_termios
    ldp     x3, x4, [x1]
    stp     x3, x4, [x2]
    ldp     x3, x4, [x1, #16]
    stp     x3, x4, [x2, #16]
    ldr     w3, [x1, #32]
    str     w3, [x2, #32]
    ldr     w3, [x2, #12]
    mov     w4, #0xa
    bic     w3, w3, w4
    str     w3, [x2, #12]
    strh    wzr, [x2, #22]
    mov     x8, #29
    mov     x0, #0
    mov     x1, #0x5402
    svc     #0

    adr     x0, sig_handler
    adr     x1, sigact
    str     x0, [x1]
    mov     w19, #2
.Lsig:
    mov     x8, #134
    mov     x0, x19
    adr     x1, sigact
    mov     x2, #0
    mov     x3, #8
    svc     #0
    cmp     w19, #15
    mov     w19, #15
    b.ne    .Lsig

    mov     x8, #64
    mov     x0, #1
    adr     x1, seq_hide
    mov     x2, #(seq_hide_len + seq_cls_len)
    svc     #0

    LB      w22, cfg_density
    mov     w19, #0
.Lseed:
    bl      rand_byte
    adr     x1, density_seed_tbl
    ldrb    w1, [x1, x22]
    cmp     w0, w1
    b.hs    .Lsk
    bl      init_column
    bl      rand_byte
    adr     x1, rows
    ldr     x1, [x1]
    udiv    x2, x0, x1
    msub    x2, x2, x1, x0
    add     x2, x2, #1
    adr     x3, col_head
    strh    w2, [x3, x19, lsl #1]
.Lsk:
    add     w19, w19, #1
    adr     x0, cols
    ldr     x0, [x0]
    cmp     w19, w0
    b.lo    .Lseed

.Lloop:
    bl      update_and_draw
    bl      flush
    bl      read_input
    LB      w0, cfg_speed
    adr     x1, speed_nsec_tbl
    ldr     w0, [x1, x0, lsl #2]
    adr     x1, tv
    str     xzr, [x1]
    str     x0, [x1, #8]
    mov     x8, #101
    adr     x0, tv
    mov     x1, #0
    svc     #0
    b       .Lloop
