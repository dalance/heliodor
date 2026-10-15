# Non-cacheable access smoke test on the arch harness (M-mode, UART at
# 0x10000000, tohost at 0x80001000: 1 = PASS, 3 = FAIL).
#   - byte stores to the UART data register and a byte load from it
#   - a cacheable store/load pair around them
#   - a misaligned IO load takes a load access fault (cause 5)
#   - an AMO to IO takes a store/AMO access fault (cause 7)

    .section .text.init
    .globl _start
_start:
    la        t0, trap
    csrw      mtvec, t0
    li        s0, 0                 # stage
    li        s1, 0x10000000        # UART
    li        t1, 'O'
    sb        t1, 0(s1)
    li        t1, 'K'
    sb        t1, 0(s1)
    li        t1, '\n'
    sb        t1, 0(s1)
    lbu       t2, 5(s1)             # IO load, any value
    li        t3, 0x80010000
    li        t4, 0x0123456789abcdef
    sd        t4, 0(t3)
    sb        t1, 0(s1)
    ld        t5, 0(t3)
    bne       t5, t4, fail

    li        s0, 1
    lh        t1, 1(s1)             # misaligned IO load -> cause 5
    j         fail
stage2:
    li        s0, 2
    amoadd.w  t1, t1, (s1)          # AMO to IO -> cause 7
    j         fail
stage3:
    li        t0, 1
    j         done

trap:
    csrr      t0, mcause
    li        t1, 1
    beq       s0, t1, chk5
    li        t1, 2
    beq       s0, t1, chk7
    j         fail
chk5:
    li        t1, 5
    bne       t0, t1, fail
    la        t0, stage2
    csrw      mepc, t0
    mret
chk7:
    li        t1, 7
    bne       t0, t1, fail
    la        t0, stage3
    csrw      mepc, t0
    mret

fail:
    li        t0, 3
done:
    li        t1, 0x80001000
    sw        t0, 0(t1)
1:  j         1b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:   .dword 0
    .globl fromhost
fromhost: .dword 0
