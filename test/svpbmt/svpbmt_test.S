# P10 Svpbmt: page-based memory types (PTE[62:61] = PBMT).
#
# The cache-bypass effect of NC/IO cannot be observed in software on heliodor's
# coherent core, so this test pins the *interpretation* of the PBMT field:
#   - menvcfg.PBMTE gates Svpbmt. With PBMTE=0 the implementation behaves as
#     though Svpbmt were not implemented: PBMT (bits 62:61) is then a reserved
#     PTE field and ANY non-zero value raises a page fault. A PBMT=0 leaf still
#     translates normally.
#   - With PBMTE=1, PBMT=01 (NC) / 10 (IO) are valid leaf encodings (no fault)
#     and PBMT=11 is reserved -> page fault.
# (This matches the Sail reference / ACT4 `Sv/sv39_svpbmt_disabled` suite. An
# earlier version of this test wrongly assumed PBMTE=0 *ignored* PBMT.)
#
# M-mode throughout (MPRV=1/MPP=S translates loads). The trap handler signals a
# load page fault in s5 and resumes the M-mode flow via `jr mepc+4` (NOT mret:
# trap entry overwrites MPP with M, which would make MPRV use M-mode — no
# translation — for every later load; the handler restores MPP=S and jr keeps us
# in M-mode). .option norvc keeps every load 4 bytes so mepc+4 is exact, so all
# scenarios chain in one run. tohost @ 0x80001000: 1 = PASS, 10 = FAIL.
#
#   VA 0x40000000 (VPN0=0, L0[0]) -> PA 0x80020000, PBMT=01 (NC)
#   VA 0x40001000 (VPN0=1, L0[1]) -> PA 0x80021000, PBMT=11 (reserved)
#   VA 0x40002000 (VPN0=2, L0[2]) -> PA 0x80022000, PBMT=00 (normal)

    .section .text.init
    .option norvc
    .globl _start
_start:
    la   t0, mtrap
    csrw mtvec, t0

    # ---- data ----
    li   t0, 0x80020000
    li   t1, 0xACAC
    sd   t1, 0(t0)
    li   t0, 0x80021000
    li   t1, 0xB1B1
    sd   t1, 0(t0)
    li   t0, 0x80022000
    li   t1, 0xCECE
    sd   t1, 0(t0)

    # ---- page tables ----
    li   t0, 0x80010008          # L2[1] -> L1
    li   t1, 0x20004401
    sd   t1, 0(t0)
    li   t0, 0x80011000          # L1[0] -> L0
    li   t1, 0x20004801
    sd   t1, 0(t0)
    li   t0, 0x80012000          # L0[0] -> PA 0x80020000, PBMT=01 (NC)
    li   t1, 0x20000000200080C7
    sd   t1, 0(t0)
    li   t0, 0x80012008          # L0[1] -> PA 0x80021000, PBMT=11 (reserved)
    li   t1, 0x60000000200084C7
    sd   t1, 0(t0)
    li   t0, 0x80012010          # L0[2] -> PA 0x80022000, PBMT=00 (normal)
    li   t1, 0x00000000200088C7
    sd   t1, 0(t0)

    # ---- enable Sv39 (PBMTE still 0) ----
    li   t0, 0x8000000000080010
    csrw satp, t0
    sfence.vma zero, zero

    # ---- MPRV=1, MPP=S ----
    li   t0, 0x20800
    csrs mstatus, t0

    # ---- PBMTE=0: a PBMT=0 leaf translates normally (no fault) ----
    li   s5, 0
    li   a0, 0x40002000
    ld   a1, 0(a0)               # must NOT fault
    bnez s5, fail
    li   t1, 0xCECE
    bne  a1, t1, fail            # cacheable path -> reads the value we wrote

    # ---- PBMTE=0: PBMT=01 is reserved (Svpbmt off) -> page fault ----
    li   s5, 0
    li   a0, 0x40000000
    ld   a1, 0(a0)               # must fault
    beqz s5, fail                # no fault -> bug

    # ---- PBMTE=0: PBMT=11 is reserved (Svpbmt off) -> page fault ----
    li   s5, 0
    li   a0, 0x40001000
    ld   a1, 0(a0)               # must fault
    beqz s5, fail

    # ---- enable PBMTE ----
    li   t0, 1
    slli t0, t0, 62              # menvcfg.PBMTE (bit 62)
    csrs menvcfg, t0
    sfence.vma zero, zero        # flush TLB so PBMT is re-interpreted

    # ---- PBMTE=1: PBMT=01 (NC) is a valid leaf -> no fault ----
    li   s5, 0
    li   a0, 0x40000000
    ld   a1, 0(a0)               # must NOT fault; value not checked
    bnez s5, fail                # (uncached vs cached data not comparable)

    # ---- PBMTE=1: PBMT=11 -> reserved -> page fault ----
    li   s5, 0
    li   a0, 0x40001000
    ld   a1, 0(a0)               # must fault
    beqz s5, fail

    # ---- all scenarios matched -> PASS ----
    li   t0, 0x20000
    csrc mstatus, t0             # MPRV off
    li   t0, 1
    li   t1, 0x80001000
    sw   t0, 0(t1)
1:  j    1b

mtrap:
    csrr t6, mcause
    li   t5, 13                  # load page fault
    bne  t6, t5, fail_trap
    li   s5, 1                   # signal: a load page fault occurred
    # Trap entry forced MPP=M; restore MPP=S so MPRV keeps translating loads as
    # S-mode after we resume. We stay in M-mode (jr, not mret).
    li   t0, 0x1800
    csrc mstatus, t0             # clear MPP
    li   t0, 0x800
    csrs mstatus, t0             # MPP = S (MPRV already 1)
    csrr t0, mepc
    addi t0, t0, 4               # skip the faulting (4-byte) load
    jr   t0

fail_trap:
fail:
    li   t0, 0x20000
    csrc mstatus, t0
    li   t0, 10
    li   t1, 0x80001000
    sw   t0, 0(t1)
3:  j    3b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
