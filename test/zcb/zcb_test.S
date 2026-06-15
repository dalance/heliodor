# P10 Zcb: additional compressed integer instructions. Each is expanded by the
# c_expander to its 32-bit equivalent (all of which heliodor already decodes:
# lbu/lhu/lh/sb/sh, andi/xori, sext.b/h + zext.h + add.uw (B), mul (M)).
#
# Zcb ops use only x8..x15 and small immediates (byte offset 0..3, halfword
# offset 0/2). M-mode, tohost @ 0x80001000.  1 = PASS, 6 = FAIL.

    .section .text.init
    .globl _start
_start:
    la   a1, databuf                 # a1 = RW scratch (DRAM, writable)

    # ---- c.sb / c.lbu (byte store + zero-extending byte load) ----
    li   a0, 0xAB
    c.sb  a0, 3(a1)
    c.lbu a3, 3(a1)                  # 0x00000000000000AB
    li   a4, 0xAB
    bne  a3, a4, fail

    li   a0, 0xF5                    # high bit set: c.lbu must zero-extend
    c.sb  a0, 1(a1)
    c.lbu a3, 1(a1)
    li   a4, 0xF5
    bne  a3, a4, fail

    # ---- c.sh / c.lhu / c.lh (halfword store + un/signed halfword load) ----
    li   a0, 0x8000                  # sign bit set
    c.sh  a0, 2(a1)
    c.lhu a3, 2(a1)                  # 0x0000000000008000
    li   a4, 0x8000
    bne  a3, a4, fail
    c.lh  a3, 2(a1)                  # 0xFFFFFFFFFFFF8000 (sign-ext)
    li   a4, 0xFFFFFFFFFFFF8000
    bne  a3, a4, fail

    li   a0, 0x1234
    c.sh  a0, 0(a1)
    c.lh  a3, 0(a1)                  # positive -> 0x1234
    li   a4, 0x1234
    bne  a3, a4, fail

    # ---- c.zext.b ----
    li   a0, 0x123456789AB0CDEF
    c.zext.b a0                      # 0xEF
    li   a4, 0xEF
    bne  a0, a4, fail

    # ---- c.sext.b ----
    li   a0, 0x80                    # -> 0xFFFFFFFFFFFFFF80
    c.sext.b a0
    li   a4, 0xFFFFFFFFFFFFFF80
    bne  a0, a4, fail

    # ---- c.zext.h ----
    li   a0, 0x1234FFFFABCD
    c.zext.h a0                      # 0xABCD
    li   a4, 0xABCD
    bne  a0, a4, fail

    # ---- c.sext.h ----
    li   a0, 0x8001                  # -> 0xFFFFFFFFFFFF8001
    c.sext.h a0
    li   a4, 0xFFFFFFFFFFFF8001
    bne  a0, a4, fail

    # ---- c.zext.w ----
    li   a0, -1                      # 0xFFFFFFFFFFFFFFFF -> 0x00000000FFFFFFFF
    c.zext.w a0
    li   a4, 0xFFFFFFFF
    bne  a0, a4, fail

    # ---- c.not ----
    li   a0, 0x0F0F0F0F0F0F0F0F
    c.not a0                         # 0xF0F0F0F0F0F0F0F0
    li   a4, 0xF0F0F0F0F0F0F0F0
    bne  a0, a4, fail

    # ---- c.mul ----
    li   a0, 7
    li   a1, 6
    c.mul a0, a1                     # 42
    li   a4, 42
    bne  a0, a4, fail

    # negative * positive
    li   a0, -3
    li   a1, 5
    c.mul a0, a1                     # -15
    li   a4, -15
    bne  a0, a4, fail

    # pass
    li   t0, 1
    li   t1, 0x80001000
    sw   t0, 0(t1)
done:
    j    done
fail:
    li   t0, 6
    li   t1, 0x80001000
    sw   t0, 0(t1)
fail_done:
    j    fail_done

    .align 3
databuf:
    .zero 16

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
