%ifdef WIN
bits 64
IMG equ 0x400000
section .hdr start=0 vstart=IMG progbits
    db 'MZ'
    times 0x3a db 0
    dd 0x40
    db 'PE', 0, 0
    dw 0x8664, 1
    dd 0, 0, 0
    dw 0xF0, 0x0023
    dw 0x20b
    db 1, 0
    dd 0x1000, 0x1000, 0, _start - IMG, 0x1000
    dq IMG
    dd 0x1000, 0x200
    dw 6, 0, 0, 0, 6, 0
    dd 0
    dd 0x19000, 0x200, 0
    dw 3, 0
    dq 0x100000, 0x1000, 0x100000, 0x1000
    dd 0, 16
    dd 0, 0
    dd imp_dir - IMG, 60
    times 28 dd 0
    db '.all', 0, 0, 0, 0
    dd 0x18000, 0x1000, idata_end - (IMG + 0x1000), 0x200
    dd 0, 0
    dw 0, 0
    dd 0xE0000060
    align 0x200, db 0
section .text follows=.hdr vstart=IMG+0x1000 progbits
section .bss nobits vfollows=.text
%define SEC_DATA section .text
%macro api 1
    lea     rax, [__imp_%1]
    call    callapi
%endmacro
%else
global _start
%define SEC_DATA section .data
%endif
DEFAULT REL

MAX_COLS    equ 512
BUF_SIZE    equ 65536
%ifndef WIN
TIOCGWINSZ  equ 0x5413
TCGETS      equ 0x5401
TCSETS      equ 0x5402
SA_RESTORER equ 0x04000000
%endif

%macro slot 1+
%%b:    db %%e - %%a
%%a:    db %1
%%e:
        times 24 - ($ - %%b) db 0
%endmacro

%macro optm 3
    lea     rsi, [%1]
    mov     ecx, %2
    push    rdi
    repe cmpsb
    pop     rdi
    je      %3
%endmacro

section .bss
    rows        resq 1
    cols        resq 1
    ws          resw 4
    col_head    resw MAX_COLS
    col_len     resb MAX_COLS
    col_speed   resb MAX_COLS
    col_timer   resb MAX_COLS
    wbuf        resb BUF_SIZE
    wbuf_pos    resq 1
    rng         resq 1
%ifdef WIN
    hOut        resq 1
    hErr        resq 1
    hIn         resq 1
    oldmode     resd 1
    written     resd 1
    nev         resd 1
    csbi        resb 24
    cmdbuf      resb 2048
    argv_arr    resq 16
    inrec       resb 320
%else
    sigact      resb 32
    orig_termios resb 36
    raw_termios  resb 36
    input_buf    resb 16
    tv_sec      resq 1
    tv_nsec     resq 1
%endif

SEC_DATA
    cfg_density    db 4
    cfg_speed      db 6
    cfg_color_mode db 1
    cfg_color_a    db 0
    cfg_color_b    db 255
    cfg_color_c    db 70

    seq_hide        db 0x1b, "[?25l"
    seq_hide_len    equ $ - seq_hide
    seq_cls         db 0x1b, "[2J", 0x1b, "[H"
    seq_cls_len     equ $ - seq_cls
    seq_show        db 0x1b, "[0m", 0x1b, "[?25h", 0x0a
    seq_show_len    equ $ - seq_show

    seq_erase       db 4, 0x1b, "[0m"
    clr_pre         db 0x1b, "[0;38;"

seqs:
    slot 0x1b, "[0;38;2;255;255;255m"
    times 48 db 0
    slot 0x1b, "[0;38;2;70;70;70m"

    color_tbl:
    db   0, 255,  70, 'g'
    db 255,  50,  50, 'r'
    db  60, 130, 255, 'b'
    db   0, 230, 230, 'c'
    db 255, 210,   0, 'y'
    db 255, 255, 255, 'w'

    density_seed_tbl  db   4,  8, 16, 22, 30, 42, 60, 90, 128
    density_wake_tbl  db   1,  1,  2,  3,  4,  6,  9, 15,  28
    speed_nsec_tbl  dd  90000000, 70000000, 55000000, 42000000, 33000000, \
                        24000000, 16000000, 10000000,  6000000
    drop_min_tbl    db  4, 3, 3, 2, 2, 2, 1, 1, 1
    drop_max_tbl    db  8, 7, 6, 5, 4, 4, 3, 2, 2
    drop_len_min_tbl db  5,  5,  6,  6,  6,  8,  8, 10, 12
    drop_len_max_tbl db 16, 18, 20, 22, 24, 26, 28, 30, 32

    chars   db "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            db "0123456789@#$%^&*|/<>[]{}:;"
    chars_len equ $ - chars

    o_help      db "help", 0
    o_density   db "density", 0
    o_speed     db "speed", 0
    o_color     db "color", 0

    err_prefix      db "asmatrix: unknown option: "
    err_prefix_len  equ $ - err_prefix

    help_text:
    db "Usage: asmatrix [--density 1-9] [--speed 1-9] [--color SPEC]", 0x0a
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

%ifdef WIN
callapi:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 48
    and     rsp, -16
    mov     qword [rsp + 32], 0
    call    qword [rax]
    mov     rsp, rbp
    pop     rbp
    ret

ctrl_handler:
    mov     rcx, [hOut]
    mov     edx, [oldmode]
    api     SetConsoleMode
    mov     rcx, [hOut]
    lea     rdx, [seq_cls]
    mov     r8d, seq_cls_len + seq_show_len
    lea     r9, [written]
    api     WriteFile
    xor     ecx, ecx
    api     ExitProcess

flush:
    mov     rcx, [hOut]
    lea     rdx, [wbuf]
    mov     r8, [wbuf_pos]
    lea     r9, [written]
    api     WriteFile
    mov     qword [wbuf_pos], 0
    ret
%else
sig_handler:
    mov     eax, 16
    xor     edi, edi
    mov     esi, TCSETS
    lea     rdx, [orig_termios]
    syscall
    mov     eax, 1
    mov     edi, 1
    lea     rsi, [seq_cls]
    mov     edx, seq_cls_len + seq_show_len
    syscall
    xor     edi, edi
    mov     eax, 60
    syscall

flush:
    mov     eax, 1
    mov     edi, 1
    lea     rsi, [wbuf]
    mov     rdx, [wbuf_pos]
    syscall
    mov     qword [wbuf_pos], 0
    ret
%endif

dec_to_buf:
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    test    eax, eax
    jz      .l
    push    rdx
    call    dec_to_buf
    pop     rdx
.l:
    add     dl, '0'
    mov     [rdi], dl
    inc     rdi
    ret

rand_byte:
    mov     rax, [rng]
    test    rax, rax
    jnz     .go
    rdtsc
    shl     rdx, 32
    or      rax, rdx
    or      rax, 1
.go:
    mov     rcx, rax
    shl     rcx, 13
    xor     rax, rcx
    mov     rcx, rax
    shr     rcx, 7
    xor     rax, rcx
    mov     rcx, rax
    shl     rcx, 17
    xor     rax, rcx
    mov     [rng], rax
    shr     rax, 32
    movzx   eax, al
    ret

rand_range:
    sub     esi, edi
    inc     esi
    call    rand_byte
    xor     edx, edx
    div     esi
    lea     eax, [rdx + rdi]
    ret

random_char:
    call    rand_byte
    xor     edx, edx
    mov     ecx, chars_len
    div     ecx
    movzx   eax, byte [chars + rdx]
    ret

init_column:
    movzx   r8d, byte [cfg_speed]
    mov     word [col_head + rbx*2], 0
    movzx   edi, byte [drop_len_min_tbl + r8]
    movzx   esi, byte [drop_len_max_tbl + r8]
    call    rand_range
    mov     [col_len + rbx], al
    movzx   edi, byte [drop_min_tbl + r8]
    movzx   esi, byte [drop_max_tbl + r8]
    call    rand_range
    mov     [col_speed + rbx], al
    mov     [col_timer + rbx], al
    ret

put_cell:
    cmp     rax, [rows]
    jae     put_raw.r
    mov     r9, rax
    call    random_char
    mov     r8d, eax
put_raw:
    lea     r10, [wbuf]
    add     r10, [wbuf_pos]
    mov     rdi, r10
    movzx   ecx, byte [rsi]
    inc     rsi
    rep     movsb
    mov     ax, 0x5b1b
    stosw
    lea     eax, [r9 + 1]
    call    dec_to_buf
    mov     al, ';'
    stosb
    lea     eax, [rbx + 1]
    call    dec_to_buf
    mov     al, 'H'
    stosb
    mov     al, r8b
    stosb
    sub     rdi, r10
    add     [wbuf_pos], rdi
.r:
    ret

update_and_draw:
    push    rbx
    push    r12
    push    r13
    push    r15
    movzx   r12d, byte [cfg_density]
    xor     ebx, ebx
.col:
    cmp     qword [wbuf_pos], BUF_SIZE - 256
    jb      .nf
    call    flush
.nf:
    cmp     byte [col_len + rbx], 0
    jne     .active
    call    rand_byte
    cmp     al, [density_wake_tbl + r12]
    jae     .next
    call    init_column
    jmp     .next
.active:
    dec     byte [col_timer + rbx]
    jnz     .redraw
    mov     al, [col_speed + rbx]
    mov     [col_timer + rbx], al
    movzx   r13d, word [col_head + rbx*2]
    inc     r13d
    mov     [col_head + rbx*2], r13w
    movzx   ecx, byte [col_len + rbx]
    mov     rax, r13
    sub     rax, rcx
    dec     rax
    cmp     rax, [rows]
    jge     .deact
    test    rax, rax
    js      .noerase
    mov     r9, rax
    mov     r8d, ' '
    lea     rsi, [seq_erase]
    call    put_raw
.noerase:
    mov     r15d, 1
.dr:
    mov     rax, r13
    sub     rax, r15
    lea     rsi, [r15 + r15*2]
    lea     rsi, [seqs - 24 + rsi*8]
    call    put_cell
    inc     r15d
    cmp     r15d, 4
    jbe     .dr
    jmp     .next
.redraw:
    movzx   eax, word [col_head + rbx*2]
    dec     eax
    lea     rsi, [seqs]
    call    put_cell
    jmp     .next
.deact:
    mov     byte [col_len + rbx], 0
.next:
    inc     ebx
    cmp     ebx, [cols]
    jb      .col
    pop     r15
    pop     r13
    pop     r12
    pop     rbx
    ret

%ifdef WIN
read_input:
    mov     dword [nev], 0
    mov     rcx, [hIn]
    lea     rdx, [nev]
    api     GetNumberOfConsoleInputEvents
    cmp     dword [nev], 0
    je      .r
    mov     rcx, [hIn]
    lea     rdx, [inrec]
    mov     r8d, 16
    lea     r9, [nev]
    api     ReadConsoleInputW
    mov     ecx, [nev]
    lea     rsi, [inrec]
.lp:
    test    ecx, ecx
    jz      .r
    cmp     word [rsi], 1
    jne     .n
    cmp     dword [rsi + 4], 0
    je      .n
    movzx   eax, word [rsi + 10]
    cmp     eax, 0x26
    je      .up
    cmp     eax, 0x28
    jne     .n
    cmp     byte [cfg_speed], 0
    je      .n
    dec     byte [cfg_speed]
    jmp     .n
.up:
    cmp     byte [cfg_speed], 8
    jae     .n
    inc     byte [cfg_speed]
.n:
    add     rsi, 20
    dec     ecx
    jmp     .lp
.r:
    ret

%else
read_input:
    xor     eax, eax
    xor     edi, edi
    lea     rsi, [input_buf]
    mov     edx, 15
    syscall
    test    eax, eax
    jle     .r
    lea     rdx, [rsi + rax - 2]
.scan:
    cmp     rsi, rdx
    jae     .r
    cmp     word [rsi], 0x5b1b
    jne     .n
    movzx   eax, byte [rsi + 2]
    cmp     al, 'A'
    je      .up
    cmp     al, 'B'
    jne     .n
    cmp     byte [cfg_speed], 0
    je      .s
    dec     byte [cfg_speed]
    jmp     .s
.up:
    cmp     byte [cfg_speed], 8
    jae     .s
    inc     byte [cfg_speed]
.s:
    add     rsi, 2
.n:
    inc     rsi
    jmp     .scan
.r:
    ret

%endif

hex_val:
    sub     al, '0'
    cmp     al, 9
    jbe     .r
    sub     al, 'A' - '0'
    cmp     al, 5
    jbe     .u
    sub     al, 'a' - 'A'
    cmp     al, 5
    jbe     .u
    mov     al, 0xFF
    ret
.u:
    add     al, 10
.r:
    ret

emit_color_seq:
    push    rdi
    inc     rdi
    mov     r8d, esi
    lea     rsi, [clr_pre]
    mov     ecx, 7
    rep     movsb
    cmp     byte [cfg_color_mode], 2
    jne     .rgb
    add     byte [rdi - 5], r8b
    mov     ax, 0x3b35
    stosw
    movzx   eax, byte [cfg_color_a]
    call    dec_to_buf
    jmp     .fin
.rgb:
    mov     ax, 0x3b32
    stosw
    xor     r9d, r9d
.c:
    movzx   eax, byte [cfg_color_a + r9]
    test    r8d, r8d
    jnz     .nb
    lea     eax, [rax + rax*2]
    shr     eax, 2
.nb:
    call    dec_to_buf
    inc     r9d
    cmp     r9d, 3
    je      .fin
    mov     al, ';'
    stosb
    jmp     .c
.fin:
    mov     al, 'm'
    stosb
    pop     rcx
    sub     rdi, rcx
    dec     edi
    mov     [rcx], dil
    ret

parse_color_value:
    mov     rbx, rsi
    cmp     byte [rbx], '#'
    jne     .hex
    inc     rbx
.hex:
    xor     ecx, ecx
.hp:
    movzx   eax, byte [rbx + rcx*2]
    call    hex_val
    cmp     al, 0xFF
    je      .nothex
    mov     dl, al
    shl     dl, 4
    movzx   eax, byte [rbx + rcx*2 + 1]
    call    hex_val
    cmp     al, 0xFF
    je      .nothex
    or      al, dl
    mov     [cfg_color_a + rcx], al
    inc     ecx
    cmp     ecx, 3
    jb      .hp
    cmp     byte [rbx + 6], 0
    jne     .nothex
    mov     byte [cfg_color_mode], 1
    jmp     .ok
.nothex:
    cmp     byte [rsi], '#'
    je      .fail
    xor     ecx, ecx
    xor     edx, edx
.nl:
    movzx   eax, byte [rbx + rcx]
    test    al, al
    jz      .nd
    sub     al, '0'
    cmp     al, 9
    ja      .name
    cmp     ecx, 3
    jae     .name
    imul    edx, edx, 10
    add     edx, eax
    inc     ecx
    jmp     .nl
.nd:
    test    ecx, ecx
    jz      .name
    cmp     edx, 255
    ja      .name
    mov     [cfg_color_a], dl
    mov     byte [cfg_color_mode], 2
    jmp     .ok
.name:
    mov     al, [rbx]
    lea     rdx, [color_tbl]
    mov     ecx, 6
.nm:
    cmp     al, [rdx + 3]
    je      .found
    add     rdx, 4
    loop    .nm
.fail:
    mov     eax, 1
    ret
.found:
    mov     eax, [rdx]
    shl     eax, 8
    mov     al, 1
    mov     [cfg_color_mode], eax
.ok:
    xor     eax, eax
    ret

parse_arg:
    cmp     word [rdi], '--'
    jne     .plain
    add     rdi, 2
    mov     rdx, rsi
    optm    o_help, 5, .help
    optm    o_density, 8, .density
    optm    o_speed, 6, .speed
    optm    o_color, 6, .color
.unknown:
    mov     eax, 2
    ret
.help:
    mov     eax, 1
    ret
.density:
    lea     rdi, [cfg_density]
    jmp     .num
.speed:
    lea     rdi, [cfg_speed]
.num:
    test    rdx, rdx
    jz      .unknown
    movzx   eax, byte [rdx]
    sub     al, '1'
    cmp     al, 8
    ja      .unknown
    mov     [rdi], al
.used:
    mov     eax, 3
    ret
.color:
    test    rdx, rdx
    jz      .unknown
    mov     rsi, rdx
    call    parse_color_value
    test    eax, eax
    jnz     .unknown
    jmp     .used
.plain:
    xor     eax, eax
    ret

%ifdef WIN
print_unknown_arg:
    push    rdi
    mov     rcx, [hErr]
    lea     rdx, [err_prefix]
    mov     r8d, err_prefix_len
    lea     r9, [written]
    api     WriteFile
    pop     rsi
    mov     rdi, rsi
    xor     eax, eax
    or      rcx, -1
    repne scasb
    mov     byte [rdi - 1], 0x0a
    mov     r8, rdi
    sub     r8, rsi
    mov     rdx, rsi
    mov     rcx, [hErr]
    lea     r9, [written]
    api     WriteFile
    ret

%else
print_unknown_arg:
    push    rdi
    mov     eax, 1
    mov     edi, 2
    lea     rsi, [err_prefix]
    mov     edx, err_prefix_len
    syscall
    pop     rsi
    mov     rdi, rsi
    xor     eax, eax
    or      rcx, -1
    repne scasb
    mov     byte [rdi - 1], 0x0a
    mov     rdx, rdi
    sub     rdx, rsi
    mov     edi, 2
    mov     eax, 1
    syscall
    ret

%endif

_start:
%ifdef WIN
    mov     ecx, -11
    api     GetStdHandle
    mov     [hOut], rax
    mov     ecx, -12
    api     GetStdHandle
    mov     [hErr], rax
    mov     ecx, -10
    api     GetStdHandle
    mov     [hIn], rax
    api     GetCommandLineA
    mov     rsi, rax
    lea     rdi, [cmdbuf]
    mov     ecx, 2047
.wcp:
    lodsb
    stosb
    test    al, al
    loopnz  .wcp
    lea     rsi, [cmdbuf]
    lea     rdi, [argv_arr]
    xor     r13d, r13d
.wsk:
    mov     al, [rsi]
    cmp     al, ' '
    jne     .wt
    inc     rsi
    jmp     .wsk
.wt:
    test    al, al
    jz      .wdone
    cmp     r13d, 14
    jae     .wdone
    mov     dl, ' '
    cmp     al, '"'
    jne     .wa
    mov     dl, al
    inc     rsi
.wa:
    mov     [rdi], rsi
    add     rdi, 8
    inc     r13d
.ws:
    mov     al, [rsi]
    test    al, al
    jz      .wdone
    cmp     al, dl
    je      .we
    inc     rsi
    jmp     .ws
.we:
    mov     byte [rsi], 0
    inc     rsi
    jmp     .wsk
.wdone:
    lea     r15, [argv_arr + 8]
    dec     r13
    mov     rcx, [hOut]
    lea     rdx, [csbi]
    api     GetConsoleScreenBufferInfo
    test    eax, eax
    jz      .wnosz
    movzx   eax, word [csbi + 14]
    movzx   ecx, word [csbi + 10]
    sub     eax, ecx
    inc     eax
    mov     [ws + 2], ax
    movzx   eax, word [csbi + 16]
    movzx   ecx, word [csbi + 12]
    sub     eax, ecx
    inc     eax
    mov     [ws], ax
.wnosz:
%else
    mov     r13, [rsp]
    lea     r15, [rsp + 16]
    dec     r13

    mov     eax, 16
    mov     edi, 1
    mov     esi, TIOCGWINSZ
    lea     rdx, [ws]
    syscall
%endif

    movzx   eax, word [ws]
    mov     ecx, 24
    test    eax, eax
    cmovz   eax, ecx
    mov     [rows], rax
    movzx   eax, word [ws + 2]
    mov     ecx, 80
    test    eax, eax
    cmovz   eax, ecx
    mov     ecx, MAX_COLS
    cmp     eax, ecx
    cmova   eax, ecx
    mov     [cols], rax

.arg_loop:
    test    r13, r13
    jz      .arg_done
    mov     rdi, [r15]
    mov     rsi, [r15 + 8]
    call    parse_arg
    cmp     eax, 1
    je      .do_help
    cmp     eax, 2
    je      .do_unknown
    add     r15, 8
    dec     r13
    cmp     eax, 3
    jne     .arg_loop
    add     r15, 8
    dec     r13
    jmp     .arg_loop
.do_unknown:
    mov     rdi, [r15]
    call    print_unknown_arg
    mov     ebx, 1
    jmp     .help_out
.do_help:
    xor     ebx, ebx
.help_out:
%ifdef WIN
    mov     rcx, [hOut]
    lea     rdx, [help_text]
    mov     r8d, help_text_len
    lea     r9, [written]
    api     WriteFile
    mov     ecx, ebx
    api     ExitProcess
%else
    mov     eax, 1
    mov     edi, 1
    lea     rsi, [help_text]
    mov     edx, help_text_len
    syscall
    mov     edi, ebx
    mov     eax, 60
    syscall
%endif
.arg_done:

    lea     rdi, [seqs + 24]
    mov     esi, 1
    call    emit_color_seq
    lea     rdi, [seqs + 48]
    xor     esi, esi
    call    emit_color_seq

%ifdef WIN
    mov     rcx, [hOut]
    lea     rdx, [oldmode]
    api     GetConsoleMode
    mov     rcx, [hOut]
    mov     edx, [oldmode]
    or      edx, 5
    api     SetConsoleMode
    lea     rcx, [ctrl_handler]
    mov     edx, 1
    api     SetConsoleCtrlHandler
    mov     ecx, 1
    api     timeBeginPeriod
    mov     rcx, [hOut]
    lea     rdx, [seq_hide]
    mov     r8d, seq_hide_len + seq_cls_len
    lea     r9, [written]
    api     WriteFile

%else
    mov     eax, 16
    xor     edi, edi
    mov     esi, TCGETS
    lea     rdx, [orig_termios]
    syscall
    lea     rsi, [orig_termios]
    lea     rdi, [raw_termios]
    mov     ecx, 9
    rep     movsd
    and     dword [raw_termios + 12], ~(0x0002 | 0x0008)
    mov     word [raw_termios + 22], 0
    mov     eax, 16
    xor     edi, edi
    mov     esi, TCSETS
    lea     rdx, [raw_termios]
    syscall

    lea     rax, [sig_handler]
    mov     [sigact], rax
    mov     [sigact + 16], rax
    mov     qword [sigact + 8], SA_RESTORER
    mov     ebx, 2
.sig:
    mov     eax, 13
    mov     edi, ebx
    lea     rsi, [sigact]
    xor     edx, edx
    mov     r10d, 8
    syscall
    cmp     ebx, 15
    mov     ebx, 15
    jne     .sig

    mov     eax, 1
    mov     edi, 1
    lea     rsi, [seq_hide]
    mov     edx, seq_hide_len + seq_cls_len
    syscall

%endif
    movzx   r12d, byte [cfg_density]
    xor     ebx, ebx
.seed:
    call    rand_byte
    cmp     al, [density_seed_tbl + r12]
    jae     .sk
    call    init_column
    call    rand_byte
    xor     edx, edx
    div     qword [rows]
    inc     edx
    mov     [col_head + rbx*2], dx
.sk:
    inc     ebx
    cmp     ebx, [cols]
    jb      .seed

.loop:
    call    update_and_draw
    call    flush
    call    read_input
%ifdef WIN
    movzx   eax, byte [cfg_speed]
    mov     eax, [speed_nsec_tbl + rax*4]
    xor     edx, edx
    mov     ecx, 1000000
    div     ecx
    mov     ecx, eax
    api     Sleep
%else
    movzx   eax, byte [cfg_speed]
    mov     eax, [speed_nsec_tbl + rax*4]
    mov     [tv_nsec], rax
    mov     eax, 35
    lea     rdi, [tv_sec]
    xor     esi, esi
    syscall
%endif
    jmp     .loop

%ifdef WIN
imp_dir:
    dd iat_k32 - IMG, 0, 0, name_k32 - IMG, iat_k32 - IMG
    dd iat_wm - IMG, 0, 0, name_wm - IMG, iat_wm - IMG
    dd 0, 0, 0, 0, 0
%macro imp 1
__imp_%1: dq hn_%1 - IMG
%endmacro
%macro hnm 2
    align 2, db 0
hn_%1: dw 0
    db %2, 0
%endmacro
iat_k32:
    imp GetStdHandle
    imp GetCommandLineA
    imp GetConsoleMode
    imp SetConsoleMode
    imp GetConsoleScreenBufferInfo
    imp SetConsoleCtrlHandler
    imp WriteFile
    imp GetNumberOfConsoleInputEvents
    imp ReadConsoleInputW
    imp Sleep
    imp ExitProcess
    dq 0
iat_wm:
    imp timeBeginPeriod
    dq 0
name_k32: db 'KERNEL32.dll', 0
name_wm:  db 'WINMM.dll', 0
    hnm GetStdHandle, "GetStdHandle"
    hnm GetCommandLineA, "GetCommandLineA"
    hnm GetConsoleMode, "GetConsoleMode"
    hnm SetConsoleMode, "SetConsoleMode"
    hnm GetConsoleScreenBufferInfo, "GetConsoleScreenBufferInfo"
    hnm SetConsoleCtrlHandler, "SetConsoleCtrlHandler"
    hnm WriteFile, "WriteFile"
    hnm GetNumberOfConsoleInputEvents, "GetNumberOfConsoleInputEvents"
    hnm ReadConsoleInputW, "ReadConsoleInputW"
    hnm Sleep, "Sleep"
    hnm ExitProcess, "ExitProcess"
    hnm timeBeginPeriod, "timeBeginPeriod"
    times 0x200 - (($ - $$) % 0x200) db 0
idata_end:
%endif
