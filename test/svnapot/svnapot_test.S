# P10 Svnapot: NAPOT (naturally-aligned power-of-two) translation contiguity.
#
# Map a 64 KB NAPOT region: VA 0x40000000..0x4000FFFF -> PA 0x80020000..0x8002FFFF
# via 16 identical level-0 PTEs with N=1 and PPN=0x80028 (base 0x80020 with the
# low 4 bits = the 64 KB size code 0b1000). The hardware must take the low 4 PPN
# bits of the translation from VA[15:12], so two different 4 KB sub-pages map to
# two different physical pages. If NAPOT were ignored (N treated as a plain
# leaf), both VAs would resolve to PPN 0x80028 and read uninitialised memory.
#
# M-mode throughout (MPRV=1/MPP=S translates loads). tohost @ 0x80001000.
# 1 = PASS, 8 = FAIL.
#
#   VA 0x40000000: VPN2=1 VPN1=0 VPN0=0  -> L0[0]  -> PA 0x80020000
#   VA 0x40005000: VPN2=1 VPN1=0 VPN0=5  -> L0[5]  -> PA 0x80025000

    .section .text.init
    .globl _start
_start:
    la   t0, trap_fail
    csrw mtvec, t0

    # ---- distinct sentinels in two physical sub-pages ----
    li   t0, 0x80020000          # NAPOT base page (sub-page 0)
    li   t1, 0xA0A0
    sd   t1, 0(t0)
    li   t0, 0x80025000          # sub-page 5
    li   t1, 0xB5B5
    sd   t1, 0(t0)

    # ---- page tables: L2[1] -> L1 -> L0 ----
    li   t0, 0x80010008          # L2[1] -> L1 (PPN 0x80011)
    li   t1, 0x20004401
    sd   t1, 0(t0)
    li   t0, 0x80011000          # L1[0] -> L0 (PPN 0x80012)
    li   t1, 0x20004801
    sd   t1, 0(t0)

    # ---- 16 identical NAPOT level-0 PTEs (N=1, PPN=0x80028, V R W A D) ----
    li   t0, 0x80012000
    li   t1, 0x800000002000A0C7
    li   t2, 16
1:  sd   t1, 0(t0)
    addi t0, t0, 8
    addi t2, t2, -1
    bnez t2, 1b

    # ---- enable Sv39 ----
    li   t0, 0x8000000000080010  # MODE=8, root PPN=0x80010
    csrw satp, t0
    sfence.vma zero, zero

    # ---- MPRV=1, MPP=S ----
    li   t0, 0x20800
    csrs mstatus, t0

    # ---- sub-page 0: VA 0x40000000 -> PA 0x80020000 = 0xA0A0 ----
    li   a0, 0x40000000
    ld   a1, 0(a0)
    li   t1, 0xA0A0
    bne  a1, t1, fail

    # ---- sub-page 5: VA 0x40005000 -> PA 0x80025000 = 0xB5B5 ----
    li   a0, 0x40005000
    ld   a1, 0(a0)
    li   t1, 0xB5B5
    bne  a1, t1, fail            # if NAPOT low-bit resolve failed -> wrong PA -> fail

    li   t0, 0x20000
    csrc mstatus, t0
    li   t0, 1
    li   t1, 0x80001000
    sw   t0, 0(t1)
done:
    j    done

fail:
    li   t0, 0x20000
    csrc mstatus, t0
    li   t0, 8
    li   t1, 0x80001000
    sw   t0, 0(t1)
fail_done:
    j    fail_done

    .align 2
trap_fail:
    li   t0, 0x20000
    csrc mstatus, t0
    li   t0, 8
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
