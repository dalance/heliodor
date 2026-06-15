# P10 Supm/Ssnpm: pointer masking.
#
# In bare M-mode mseccfg.PMM selects the M-mode masking width (00=off, 10=PMLEN7,
# 11=PMLEN16). The top PMLEN bits of a data-access effective address are dropped
# (zeroed for a bare physical address), so a tagged pointer accesses the same
# location as the clean pointer.
#
# NOTE on observability: heliodor's flat DRAM model and Sv39 MMU both ignore the
# upper address bits, so a tagged-pointer load/store ALIASES to the clean
# location whether or not masking is applied — the cache-line effect is not
# software-observable (same situation as Svpbmt). The discriminating proof is
# therefore the LR/SC reservation check, which is an explicit full-address
# comparison inside the core: an SC through a tagged pointer succeeds against a
# reservation taken on the clean pointer ONLY when masking collapses the two to
# the same address. (Validated discriminating: forcing pm_mode=0 makes the
# tagged SCs fail and checks 42/44 trip.)
#
# tohost @ 0x80001000: 1 = PASS, else = failing check id. Scratch DRAM 0x80002000.

#define MSECCFG 0x747

    .section .text.init
    .globl _start
_start:
    li      s0, 0x80002000
    li      t1, 0x1111
    sd      t1, 0(s0)               # init

    # ---- 41: tagged load aliases to the clean location (coverage) ----
    li      t2, 3
    slli    t2, t2, 32              # mseccfg.PMM = 11 (PMLEN16)
    csrw    MSECCFG, t2
    li      t3, 0xFFFF000080002000
    ld      t4, 0(t3)
    li      t5, 0x1111
    li      a0, 41
    bne     t4, t5, fail

    # ---- 42/43: PMLEN16 — SC via tagged ptr matches an LR on the clean ptr ----
    lr.d    t4, (s0)                # reserve 0x80002000
    li      t1, 0x2222
    li      t3, 0xFFFF000080002000
    sc.d    t5, t1, (t3)            # masked → 0x80002000 → matches → t5=0
    li      a0, 42
    bnez    t5, fail                # SC must succeed (masking made addrs match)
    ld      t4, 0(s0)
    li      t5, 0x2222
    li      a0, 43
    bne     t4, t5, fail            # masked SC wrote the clean location

    # ---- 44/45: PMLEN7 — same, tag in bit 63 ----
    li      t2, 2
    slli    t2, t2, 32              # mseccfg.PMM = 10 (PMLEN7)
    csrw    MSECCFG, t2
    lr.d    t4, (s0)
    li      t1, 0x3333
    li      t3, 0x8000000080002000
    sc.d    t5, t1, (t3)
    li      a0, 44
    bnez    t5, fail
    ld      t4, 0(s0)
    li      t5, 0x3333
    li      a0, 45
    bne     t4, t5, fail

    # ---- 46/47: PMM=0 — clean LR/SC behaves normally ----
    csrw    MSECCFG, x0
    lr.d    t4, (s0)
    li      t1, 0x4444
    sc.d    t5, t1, (s0)
    li      a0, 46
    bnez    t5, fail
    ld      t4, 0(s0)
    li      t5, 0x4444
    li      a0, 47
    bne     t4, t5, fail

    # ---- all passed ----
    li      t0, 1
    li      t1, 0x80001000
    sw      t0, 0(t1)
1:  j       1b

fail:
    li      t1, 0x80001000
    sw      a0, 0(t1)
2:  j       2b

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
