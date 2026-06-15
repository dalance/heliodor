# P10 system bundle: Zawrs (wrs.nto/wrs.sto) + Svinval (sinval.vma /
# sfence.w.inval / sfence.inval.ir).
#
# wrs.* and the sfence.*.inval ordering fences are accepted as no-ops. The
# meaningful check is that SINVAL.VMA actually flushes the TLB (heliodor maps it
# to its SFENCE.VMA full-flush path). We prove that with a tiny Sv39 mapping:
#   map VA 0x40000000 -> PA_A, load it (fills the TLB), remap the leaf PTE to
#   PA_B, SINVAL.VMA, reload. If SINVAL.VMA flushed, the reload sees PA_B; if it
#   were a NOP, the stale TLB entry would still return PA_A and the test fails.
#
# M-mode throughout; MPRV=1/MPP=S makes M-mode loads use S-mode translation so
# we never have to leave M-mode. tohost @ 0x80001000.  1 = PASS, 7 = FAIL.
#
#   PA layout (1 MB DRAM @ 0x80000000):
#     0x80010000  L2 root PT     0x80013000  data page A (0xAAAA)
#     0x80011000  L1 PT          0x80014000  data page B (0xBBBB)
#     0x80012000  L0 PT
#   VA 0x40000000: VPN2=1, VPN1=0, VPN0=0

    .section .text.init
    .globl _start
_start:
    la   t0, trap_fail
    csrw mtvec, t0

    # ---- Zawrs + Svinval-fence smoke (must not trap, must not corrupt) ----
    li   s0, 0x1111111111111111
    li   s1, 0x2222222222222222
    wrs.nto
    wrs.sto
    sfence.w.inval
    sfence.inval.ir
    li   t1, 0x1111111111111111
    bne  s0, t1, fail
    li   t1, 0x2222222222222222
    bne  s1, t1, fail

    # ---- data pages ----
    li   t0, 0x80013000
    li   t1, 0xAAAA
    sd   t1, 0(t0)
    li   t0, 0x80014000
    li   t1, 0xBBBB
    sd   t1, 0(t0)

    # ---- Sv39 page tables (PTE = (PPN<<10)|flags) ----
    li   t0, 0x80010008          # L2[1] -> L1 (non-leaf, V)
    li   t1, 0x20004401
    sd   t1, 0(t0)
    li   t0, 0x80011000          # L1[0] -> L0 (non-leaf, V)
    li   t1, 0x20004801
    sd   t1, 0(t0)
    li   t0, 0x80012000          # L0[0] -> PA_A (leaf, V R W A D)
    li   t1, 0x20004CC7
    sd   t1, 0(t0)

    # ---- enable Sv39 ----
    li   t0, 0x8000000000080010  # MODE=8, PPN=0x80010
    csrw satp, t0
    sfence.vma zero, zero

    # ---- MPRV=1, MPP=S: M-mode loads translate via satp ----
    li   t0, 0x20800             # MPRV(bit17) | MPP=S(bit11)
    csrs mstatus, t0

    # ---- prime the TLB: VA 0x40000000 -> PA_A ----
    li   a0, 0x40000000
    ld   a1, 0(a0)
    li   t1, 0xAAAA
    bne  a1, t1, fail

    # ---- remap leaf PTE to PA_B (do it physically: clear MPRV first) ----
    li   t0, 0x20000
    csrc mstatus, t0
    li   t0, 0x80012000
    li   t1, 0x200050C7          # L0[0] -> PA_B
    sd   t1, 0(t0)

    # ---- the instruction under test: flush the stale TLB entry ----
    sinval.vma zero, zero

    # ---- reload under translation: must now observe PA_B ----
    li   t0, 0x20800
    csrs mstatus, t0
    li   a0, 0x40000000
    ld   a1, 0(a0)
    li   t1, 0xBBBB
    bne  a1, t1, fail            # stale 0xAAAA here would mean SINVAL.VMA failed

    li   t0, 0x20000             # clear MPRV before signalling
    csrc mstatus, t0
    li   t0, 1
    li   t1, 0x80001000
    sw   t0, 0(t1)
done:
    j    done

fail:
    li   t0, 0x20000
    csrc mstatus, t0             # ensure the tohost store is physical
    li   t0, 7
    li   t1, 0x80001000
    sw   t0, 0(t1)
fail_done:
    j    fail_done

    .align 2
trap_fail:
    li   t0, 0x20000
    csrc mstatus, t0
    li   t0, 7
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
