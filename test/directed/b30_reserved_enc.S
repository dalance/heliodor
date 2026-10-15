// B30: reserved encodings must raise illegal instruction.
//
// M-mode, outside debug mode: DRET 0x7b200073 (sub-case 1), a LOAD with
// the reserved funct3=7 (2), an unknown SYSTEM funct12 0x7ff (3), an AMO
// with the reserved funct5 0x02 (4). Spec: cause 2 each. 0xB01E with a sub-case mask: no trap.
#include "common/probe.h"

.macro CASE word, sub
    la      t6, trap_rec
    sd      zero, 0(t6)
    SET_RESUME 1f
    li      a5, SCRATCH
    .word   \word
1:  la      t6, trap_rec
    ld      t1, 0(t6)
    li      t0, 2
    beq     t1, t0, 2f
    PRINT   'c', t1
    ori     s10, s10, 1 << (\sub - 1)
2:
.endm

    .section .text
main:
    li      s10, 0
    CASE    0x7b200073, 1
    // ld-shaped: rd=x0, rs1=a5 (x15), funct3=7
    CASE    0x0007f003, 2
    // SYSTEM funct3=0 funct12=0x7ff rs1=rd=x0
    CASE    0x7ff00073, 3
    // AMO .d funct5=0x02 rd=x0 rs1=a5 rs2=x0
    CASE    0x0807b02f, 4
    beqz    s10, 9f
    slli    s10, s10, 16
    li      t0, CODE_BUG(30)
    or      s10, s10, t0
    REPORT_REG s10
9:  REPORT  1
