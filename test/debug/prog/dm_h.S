# Hart program of dbg/dm_h (dmi/dm_h.dmi): Debug Mode with the H extension.
# It parks in M, where the script halts it and resumes it through dret into
# HS, VS or VU (dcsr.prv and dcsr.v) at one of the seg_* sequences; each one
# ends in an ebreak, which with the dcsr.ebreak bit of its mode halts right
# after the sequence (cause 1). PMP entry 0 gives S and U all of memory.
# hgatp is Sv39x4 with its root at G_ROOT: GPA [2 GiB, 3 GiB) maps to the
# same HPA, GPA [3 GiB, 4 GiB) to HPA [2 GiB, 3 GiB); vsatp is Bare. The
# vector unit is on with vl = 4 at e64, m2. buf holds word i = 0x11110000 + i;
# vbuf dword i = 0x2222000000000000 + i. `done` writes tohost = 1.

        .option norvc
        .option arch, +v, +h
        .equ    G_ROOT, 0x80010000
        .section .text.init
        .globl _start
_start:
        la      t0, hpark
        csrw    mtvec, t0
        li      t0, -1
        csrw    pmpaddr0, t0
        li      t0, 0x1f                    # NAPOT, RWX
        csrw    pmpcfg0, t0
        li      t0, G_ROOT
        li      t1, 0x200000df              # V, R, W, X, U, A, D: HPA 2 GiB
        sd      t1, 16(t0)                  # GPA 2 GiB
        sd      t1, 24(t0)                  # GPA 3 GiB
        li      t1, 0x8000000000080010      # Sv39x4, root G_ROOT
        csrw    hgatp, t1
        csrw    vsatp, zero
        li      t0, (1 << 9)                # mstatus.VS = Initial
        csrs    mstatus, t0
        vsetivli zero, 4, e64, m2, ta, ma
park:   j       park

        .globl  seg_loop, seg_rd, seg_u, seg_hlv, seg_hsv, seg_vle, seg_vchk, hpark, buf, vbuf, vout, done
seg_loop:
        j       seg_loop
seg_rd: csrr    a3, sscratch
        ebreak
seg_u:  addi    a3, a3, 1
        ebreak
seg_hlv:
        hlv.d   a2, (a0)
        ebreak
seg_hsv:
        hsv.d   a1, (a0)
        ebreak
seg_vle:
        vle64.v v2, (a0)
        ebreak
seg_vchk:
        vse64.v v2, (a1)
        ld      a3, 0(a1)
        ld      a4, 16(a1)
        ld      a5, 24(a1)
        ebreak

        .balign 4
hpark:  j       hpark

done:   la      t0, tohost
        li      t1, 1
        sw      t1, 0(t0)
1:      j       1b

        .balign 64
buf:
        .set    i, 0
        .rept   16
        .word   0x11110000 + i
        .set    i, i + 1
        .endr
vbuf:
        .set    i, 0
        .rept   4
        .dword  0x2222000000000000 + i
        .set    i, i + 1
        .endr
vout:   .zero   32

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
