# P10 Zicond (conditional zero) directed test.
#
# Runs under test_arch_common_harness (M-mode, riscv-tests tohost @ 0x80001000).
#
#   czero.eqz rd, rs1, rs2 : rd = (rs2 == 0) ? 0 : rs1
#   czero.nez rd, rs1, rs2 : rd = (rs2 != 0) ? 0 : rs1
#
# tohost @ 0x80001000:  1 = PASS, 3 = FAIL.

    .section .text.init
    .globl _start
_start:
    # czero.eqz, rs2 == 0  -> 0
    li        t0, 0xAAAA
    li        t1, 0
    czero.eqz t2, t0, t1
    bnez      t2, fail

    # czero.eqz, rs2 != 0  -> rs1
    li        t0, 0xAAAA
    li        t1, 5
    czero.eqz t2, t0, t1
    li        t3, 0xAAAA
    bne       t2, t3, fail

    # czero.nez, rs2 == 0  -> rs1
    li        t0, 0xBBBB
    li        t1, 0
    czero.nez t2, t0, t1
    li        t3, 0xBBBB
    bne       t2, t3, fail

    # czero.nez, rs2 != 0  -> 0
    li        t0, 0xBBBB
    li        t1, 7
    czero.nez t2, t0, t1
    bnez      t2, fail

    li        t0, 1                  # PASS
    li        t1, 0x80001000
    sw        t0, 0(t1)
done:
    j         done

fail:
    li        t0, 3                  # FAIL
    li        t1, 0x80001000
    sw        t0, 0(t1)
fail_done:
    j         fail_done

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
