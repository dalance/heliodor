# Privileged-architecture directed test (M/S/U, delegation, legality, CSR
# WARL rules, interrupts that need no device).
#
# Every trap enters mtrap, which records mcause/mtval/mepc in s8/s9/s10,
# counts it in s7 and resumes in M-mode at s11. A step that must not trap
# ends with an ECALL so the resume path is the same. M-mode runs with
# mstatus.MIE = 0 throughout (mtrap clears MPIE before its MRET).
#
# tohost @ 0x80001000: 1 = PASS, else the number of the failing step (gp).

#define MSTATUS_SIE   0x2
#define MSTATUS_MIE   0x8
#define MSTATUS_MPIE  0x80
#define MSTATUS_MPP   0x1800
#define MSTATUS_MPP_S 0x0800
#define MSTATUS_SPP   0x100
#define MSTATUS_MPRV  (1 << 17)
#define MSTATUS_TW    (1 << 21)
#define CAUSE_ILL     2
#define CAUSE_BRK     3
#define CAUSE_ECALL_U 8
#define CAUSE_ECALL_S 9
#define CAUSE_ECALL_M 11
#define IRQ(n)        ((1 << 63) | (n))

    .option norvc

.macro STEP n
    li      gp, \n
    li      s7, 0
    li      s8, 0
    la      s11, fail
.endm

// The step expects a trap: resume at its local label 9.
.macro RESUME
    la      s11, 9f
.endm

.macro TO_S label
    la      t0, \label
    csrw    mepc, t0
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S
    csrs    mstatus, t0
    mret
.endm

.macro TO_U label
    la      t0, \label
    csrw    mepc, t0
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    mret
.endm

// The step's single trap had cause c.
.macro CHECK_CAUSE c
    li      t0, 1
    bne     s7, t0, fail
    li      t0, \c
    bne     s8, t0, fail
.endm

    .section .text.init
    .globl _start
_start:
    la      t0, mtrap
    csrw    mtvec, t0
    li      t0, -1
    csrw    pmpaddr0, t0
    li      t0, 0x1f
    csrw    pmpcfg0, t0
    csrw    medeleg, zero
    csrw    mideleg, zero
    csrw    mie, zero

    # misa: RV64, I M C S U, no H
    STEP 2
    csrr    t1, misa
    srli    t2, t1, 62
    li      t0, 2
    bne     t2, t0, fail
    li      t0, (1 << 8) | (1 << 12) | (1 << 2) | (1 << 18) | (1 << 20)
    and     t2, t1, t0
    bne     t2, t0, fail
    andi    t2, t1, (1 << 7)
    bnez    t2, fail
    # mhartid of hart 0; the trigger registers read zero without trapping
    csrr    t1, mhartid
    bnez    t1, fail
    csrr    t1, tselect
    bnez    t1, fail
    bnez    s7, fail

    # EBREAK: tval is the PC (32-bit and compressed)
    STEP 3
    RESUME
brk32:
    ebreak
9:  CHECK_CAUSE CAUSE_BRK
    la      t0, brk32
    bne     s9, t0, fail
    bne     s10, t0, fail
    STEP 4
    RESUME
    .option push
    .option rvc
brk16:
    c.ebreak
    .option pop
9:  CHECK_CAUSE CAUSE_BRK
    la      t0, brk16
    bne     s9, t0, fail

    # ECALL from M: cause 11, tval 0
    STEP 5
    RESUME
    ecall
9:  CHECK_CAUSE CAUSE_ECALL_M
    bnez    s9, fail

    # a CSR that does not exist: illegal, tval = the encoding
    STEP 6
    RESUME
bad_csr:
    csrr    t1, 0x7c0
9:  CHECK_CAUSE CAUSE_ILL
    la      t0, bad_csr
    lwu     t1, 0(t0)
    bne     s9, t1, fail

    # minstret counts every retired instruction
    STEP 7
    csrr    s1, minstret
    .rept 50
    addi    s2, s2, 1
    addi    s3, s3, 1
    .endr
    csrr    s4, minstret
    sub     t1, s4, s1
    li      t0, 101
    bne     t1, t0, fail

    # MRET to S clears MPRV
    STEP 8
    RESUME
    li      t0, MSTATUS_MPRV
    csrs    mstatus, t0
    TO_S    1f
1:  ecall
9:  CHECK_CAUSE CAUSE_ECALL_S
    csrr    t1, mstatus
    li      t0, MSTATUS_MPRV
    and     t1, t1, t0
    bnez    t1, fail

    # SRET to U clears MPRV
    STEP 9
    RESUME
    li      t0, MSTATUS_MPRV
    csrs    mstatus, t0
    li      t0, MSTATUS_SPP
    csrc    mstatus, t0
    la      t0, 1f
    csrw    sepc, t0
    sret
1:  ecall
9:  CHECK_CAUSE CAUSE_ECALL_U
    csrr    t1, mstatus
    li      t0, MSTATUS_MPRV
    and     t1, t1, t0
    bnez    t1, fail

    # WFI: legal in S with TW = 0, illegal in S with TW = 1 and in U
    STEP 10
    RESUME
    TO_S    1f
1:  wfi
    ecall
9:  CHECK_CAUSE CAUSE_ECALL_S
    STEP 11
    RESUME
    li      t0, MSTATUS_TW
    csrs    mstatus, t0
    TO_S    1f
1:  wfi
    ecall
9:  CHECK_CAUSE CAUSE_ILL
    li      t0, MSTATUS_TW
    csrc    mstatus, t0
    STEP 12
    RESUME
    TO_U    1f
1:  wfi
    ecall
9:  CHECK_CAUSE CAUSE_ILL

    # SFENCE.VMA in U is illegal
    STEP 13
    RESUME
    TO_U    1f
1:  sfence.vma
    ecall
9:  CHECK_CAUSE CAUSE_ILL

    # counteren: cycle in S needs mcounteren.CY, in U also scounteren.CY
    STEP 14
    RESUME
    csrw    mcounteren, zero
    csrw    scounteren, zero
    TO_S    1f
1:  rdcycle t1
    ecall
9:  CHECK_CAUSE CAUSE_ILL
    STEP 15
    RESUME
    li      t0, 1
    csrw    mcounteren, t0
    TO_S    1f
1:  rdcycle t1
    ecall
9:  CHECK_CAUSE CAUSE_ECALL_S
    STEP 16
    RESUME
    TO_U    1f
1:  rdcycle t1
    ecall
9:  CHECK_CAUSE CAUSE_ILL
    STEP 17
    RESUME
    li      t0, 1
    csrw    scounteren, t0
    TO_U    1f
1:  rdcycle t1
    ecall
9:  CHECK_CAUSE CAUSE_ECALL_U
    # mcounteren is 32 bits
    STEP 18
    li      t0, -1
    csrw    mcounteren, t0
    csrr    t1, mcounteren
    li      t0, 0xffffffff
    bne     t1, t0, fail

    # stimecmp in S needs mcounteren.TM and menvcfg.STCE
    STEP 19
    RESUME
    csrw    menvcfg, zero
    TO_S    1f
1:  csrr    t1, stimecmp
    ecall
9:  CHECK_CAUSE CAUSE_ILL
    STEP 20
    RESUME
    li      t0, 1
    slli    t0, t0, 63
    csrw    menvcfg, t0
    TO_S    1f
1:  csrr    t1, stimecmp
    ecall
9:  CHECK_CAUSE CAUSE_ECALL_S
    csrw    menvcfg, zero

    # CSR WARL rules: mepc bit 0, satp MODE, mtvec mode, menvcfg CBIE/PMM,
    # mstatus.SD and MPP
    STEP 21
    li      t0, 0x80000001
    csrw    mepc, t0
    csrr    t1, mepc
    li      t0, 0x80000000
    bne     t1, t0, fail
    li      t0, (9 << 60)
    csrw    satp, t0
    csrr    t1, satp
    bnez    t1, fail
    csrr    s1, mtvec
    la      t0, mtrap
    ori     t0, t0, 2
    csrw    mtvec, t0
    csrr    t1, mtvec
    bne     t1, s1, fail
    li      t0, 0x10
    csrw    menvcfg, t0
    li      t0, 0x20
    csrw    menvcfg, t0
    csrr    t1, menvcfg
    li      t0, 0x10
    bne     t1, t0, fail
    li      t0, (3 << 32)
    csrw    menvcfg, t0
    li      t0, (1 << 32)
    csrw    menvcfg, t0
    csrr    t1, menvcfg
    li      t0, (3 << 32)
    bne     t1, t0, fail
    csrw    menvcfg, zero
    li      t0, 1
    slli    t0, t0, 63
    csrs    mstatus, t0
    csrr    t1, mstatus
    bltz    t1, fail
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, 0x1000
    csrs    mstatus, t0
    csrr    t1, mstatus
    li      t0, MSTATUS_MPP
    and     t1, t1, t0
    bnez    t1, fail
    bnez    s7, fail

    # sie/sip show only delegated interrupts
    STEP 22
    li      t0, 2
    csrw    mie, t0
    csrr    t1, sie
    bnez    t1, fail
    csrw    mideleg, t0
    csrr    t1, sie
    bne     t1, t0, fail
    csrw    mideleg, zero
    csrw    mie, zero

    # A pending SSIP that is not delegated traps to M from S even with
    # mstatus.MIE = 0; epc is the interrupted op
    STEP 23
    RESUME
    li      t0, 2
    csrw    mie, t0
    csrw    mip, t0
    TO_S    1f
1:  nop
    j       1b
9:  li      t0, 1
    bne     s7, t0, fail
    li      t0, 1
    slli    t0, t0, 63
    ori     t0, t0, 1
    bne     s8, t0, fail
    csrw    mip, zero
    csrw    mie, zero

    # A delegated SSIP raised in S is taken in S when sstatus.SIE = 1
    STEP 24
    RESUME
    la      t0, strap
    csrw    stvec, t0
    li      t0, 2
    csrw    mideleg, t0
    csrw    mie, t0
    li      s6, 0
    TO_S    1f
1:  csrsi   sstatus, MSTATUS_SIE
    csrsi   sip, 2
2:  beqz    s6, 2b
    ecall
9:  CHECK_CAUSE CAUSE_ECALL_S
    li      t0, 1
    slli    t0, t0, 63
    ori     t0, t0, 1
    bne     s6, t0, fail
    csrw    mideleg, zero
    csrw    mie, zero

    # LCOFI pends only when a wrap sets OF; mhpmevent3 counts cycles with
    # no retire (event 6)
    STEP 25
    csrw    mip, zero
    li      t0, -1
    csrw    mhpmcounter3, t0
    li      t0, 1
    slli    t0, t0, 63
    ori     t0, t0, 6
    csrw    mhpmevent3, t0
    jal     ra, burn
    csrw    mhpmevent3, zero
    csrr    t1, mip
    srli    t1, t1, 13
    andi    t1, t1, 1
    bnez    t1, fail
    csrr    t1, mhpmcounter3
    bltz    t1, fail                # it wrapped
    STEP 26
    li      t0, -1
    csrw    mhpmcounter3, t0
    li      t0, 6
    csrw    mhpmevent3, t0
    jal     ra, burn
    csrr    t1, mip
    srli    t1, t1, 13
    andi    t1, t1, 1
    beqz    t1, fail
    csrr    t1, mhpmevent3
    bgez    t1, fail
    csrw    mhpmevent3, zero
    csrw    mip, zero

    li      t0, 1
    la      t1, tohost
    sw      t0, 0(t1)
1:  j       1b

fail:
    la      t1, tohost
    sw      gp, 0(t1)
1:  j       1b

# Cycles with dependent divides, so no lane retires in most of them.
burn:
    li      t1, 40
    li      t2, 12345
1:  div     t2, t2, t1
    addi    t2, t2, 777
    addi    t1, t1, -1
    bnez    t1, 1b
    ret

    .align 2
mtrap:
    csrr    s8, mcause
    csrr    s9, mtval
    csrr    s10, mepc
    addi    s7, s7, 1
    csrw    mepc, s11
    li      t6, MSTATUS_MPP
    csrs    mstatus, t6
    li      t6, MSTATUS_MPIE
    csrc    mstatus, t6
    mret

    .align 2
strap:
    csrr    s6, scause
    csrci   sip, 2
    sret

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
