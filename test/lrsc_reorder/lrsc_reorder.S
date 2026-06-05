# M9.4 directed test: reproduce the v4 OoO LR/SC reservation reorder bug.
#
# A tight read_lock-style loop (lr.w; addi; sc.w; bnez) on an UNCONTENDED lock.
# Single hart, M-mode, no MMU. Each sc.w depends on its lr.w (a5 = lr+1), so a
# slow (force-miss) lr.w delays the sc.w, letting the NEXT iteration's lr.w issue
# first → an older sc.w then issues and its unconditional reservation-clear wipes
# the younger lr.w's reservation → the next sc.w fails on an uncontended lock.
#
# A correct core: every sc.w succeeds (a4==0), loop counts down, tohost=1.
# The bug: some sc.w fails (a4!=0) → tohost=2. Reproduces the N=4 boot livelock
# (hart0 stuck in arch_read_lock @0x80025b58) in ~hundreds of cycles.

.section .text.init
.globl _start
_start:
    li   a0, 0x80010000     # lock scratch (DRAM, away from code+tohost)
    sw   x0, 0(a0)          # lock = 0 (unlocked, uncontended)
    li   t2, 256            # iterations

loop:
    lr.w  a5, (a0)          # load-reserved (force-miss → multi-cycle)
    addi  a5, a5, 1         # a5 = lock + 1   (sc depends on lr via a5)
    sc.w  a4, a5, (a0)      # store-conditional; a4 = 0 success / 1 fail
    bnez  a4, fail          # any sc.w failing on an uncontended lock = the bug
    addi  t2, t2, -1
    bnez  t2, loop

    li   t0, 1              # all 256 sc.w succeeded → PASS
    j    done
fail:
    li   t0, 2              # an sc.w failed → BUG reproduced
done:
    la   t1, tohost
    sw   t0, 0(t1)
1:  j    1b

.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost:   .dword 0
.globl fromhost
fromhost: .dword 0
