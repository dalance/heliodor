# P10 CMO (Zicbom/Zicboz) directed test.
#
# Runs under test_arch_common_harness (M-mode, riscv-tests tohost @ 0x80001000).
#   cbo.clean/flush/inval : legal no-ops in this coherent write-back design —
#                           they must not fault and must not corrupt the line.
#   cbo.zero              : zeroes the whole 64B block at rs1.
#
# tohost @ 0x80001000:  1 = PASS, 3 = FAIL.

    .section .text.init
    .globl _start
_start:
    li        t2, 0x80010000        # scratch line (DRAM, 64B-aligned, not tohost page)
    li        t3, 0x0123456789abcdef
    sd        t3, 0(t2)

    cbo.clean (t2)                   # no-op: data preserved
    ld        t1, 0(t2)
    bne       t1, t3, fail

    cbo.flush (t2)                   # no-op: data preserved
    ld        t1, 0(t2)
    bne       t1, t3, fail

    cbo.inval (t2)                   # no-op: data preserved
    ld        t1, 0(t2)
    bne       t1, t3, fail

    cbo.zero  (t2)                   # zero the whole block
    ld        t1, 0(t2)             # first dword
    bnez      t1, fail
    ld        t1, 56(t2)            # last dword of the 64B block
    bnez      t1, fail

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
