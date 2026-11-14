// Reserved scalar encodings that a permissive decoder would let through must
// raise illegal instruction (cause 2) with the instruction bits in mtval and
// mepc at the word. M-mode with FS on, so the FP words are not illegal for FS
// alone. mepc and sepc point past the word, so a word that executes as an
// xRET or a branch falls through to the check. Each sub-case s whose trap is
// missing or wrong sets bit s-1 of the mask; tohost is 1 when the mask is 0,
// else (mask << 8) | 0x42.
//   1 slliw with shamt[5] set       2 OP-IMM-32 funct3 010
//   3 OP-32 funct7 0 funct3 010     4 OP-32 funct7 1 funct3 001
//   5 fsqrt.s rs2 1                 6 fmv.x.w rs2 1
//   7 fclass.d funct3 010           8 fmv.w.x funct3 001
//   9 fli.d funct3 001             10 fmadd.h (no Zfh)
//  11 fnmsub.q (no Q)              12 BRANCH funct3 010, offset 4
//  13 BRANCH funct3 011, offset 4  14 JALR funct3 001
//  15 MISC-MEM funct3 011          16 MISC-MEM funct3 111
//  17 ecall rd 1                   18 ebreak rs1 1
//  19 mret rs1 1                   20 sret rd 1
//  21 wfi rs1 1                    22 fmv.x.d rs2 1 (fmvh.x.d)
#include "common/probe.h"

.macro CASE word, sub
    la      t6, trap_rec
    sd      zero, 0(t6)
    sd      zero, 8(t6)
    sd      zero, 16(t6)
    SET_RESUME 1f
    la      t0, 1f
    csrw    mepc, t0
    csrw    sepc, t0
0:  .word   \word
1:  la      t6, trap_rec
    ld      t1, 0(t6)
    li      t0, 2
    bne     t1, t0, 2f
    ld      t1, 8(t6)
    li      t0, \word
    bne     t1, t0, 2f
    ld      t1, 16(t6)
    la      t0, 0b
    beq     t1, t0, 3f
2:  li      t0, 1 << (\sub - 1)
    or      s3, s3, t0
    PRINT   'c', t1
3:
.endm

    .section .text
main:
    li      s3, 0
    li      t0, MSTATUS_FS_INIT
    csrs    mstatus, t0
    CASE    0x0200101b, 1
    CASE    0x0000201b, 2
    CASE    0x0000203b, 3
    CASE    0x0200103b, 4
    CASE    0x58100053, 5
    CASE    0xe0100053, 6
    CASE    0xe2002053, 7
    CASE    0xf0001053, 8
    CASE    0xf2101053, 9
    CASE    0x04000043, 10
    CASE    0x0600004b, 11
    CASE    0x00002263, 12
    CASE    0x00003263, 13
    CASE    0x00001067, 14
    CASE    0x0000300f, 15
    CASE    0x0000700f, 16
    CASE    0x000000f3, 17
    CASE    0x00108073, 18
    CASE    0x30208073, 19
    CASE    0x102000f3, 20
    CASE    0x10508073, 21
    CASE    0xe2100053, 22
    beqz    s3, 9f
    slli    s3, s3, 8
    ori     s3, s3, 0x42
    REPORT_REG s3
9:  REPORT  1
