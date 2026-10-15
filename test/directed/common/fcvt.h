// Table-style scaffolding for the FP conversion probes. Every case runs;
// a mismatch sets bit sub-1 of s0 and prints n=<sub>, r=<result>,
// f=<fflags>. FCVT_DONE reports 1, or CODE_BUG(n) with the mask in [23:16].

    .option arch, +zfa, +zfh

// mvin moves t0 (input bits) into fa0; insn writes the result to a0, or
// to fa1 with mvout moving it to a0.
.macro CASE sub, inbits, mvin, insn, mvout, exp, expfl
    li      t0, \inbits
    \mvin
    csrwi   fflags, 0
    \insn
    \mvout
    frflags a1
    li      a2, \exp
    li      a3, \expfl
    li      a4, \sub
    jal     ra, fcvt_check
.endm

.macro FCVT_INIT
    li      t0, MSTATUS_FS_INIT
    csrs    mstatus, t0
    li      s0, 0
.endm

.macro FCVT_DONE n
    bnez    s0, 1f
    REPORT  1
1:  slli    s0, s0, 16
    li      t0, CODE_BUG(\n)
    add     t0, t0, s0
    REPORT_REG t0
.endm

    .section .text
fcvt_check:
    bne     a0, a2, 1f
    bne     a1, a3, 1f
    ret
1:  mv      s1, ra
    mv      s2, a0
    mv      s3, a1
    mv      s4, a4
    li      t0, 1
    addi    t1, a4, -1
    sll     t0, t0, t1
    or      s0, s0, t0
    PRINT   'n', s4
    PRINT   'r', s2
    PRINT   'f', s3
    mv      ra, s1
    ret
