# Hart program of dbg/dm_ebreak (dmi/dm_ebreak.dmi). It parks in a loop,
# where the script halts it, points dpc at seg_eb with dcsr.prv set to M, S or
# U and resumes: with dcsr.ebreakm/s/u for that privilege the ebreak enters
# Debug Mode (cause 1), without it the ebreak is a breakpoint exception taken
# to M, whose handler spins in hpark until the script halts it. PMP entry 0
# gives S and U all of memory. `done` writes tohost = 1.

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, handler
        csrw    mtvec, t0
        li      t0, -1
        csrw    pmpaddr0, t0
        li      t0, 0x1f                    # NAPOT, RWX
        csrw    pmpcfg0, t0
park:   j       park

        .globl  seg_eb, handler, hpark, done
seg_eb: ebreak
        j       seg_eb

        .balign 4
handler:
hpark:  j       hpark

done:   la      t0, tohost
        li      t1, 1
        sw      t1, 0(t0)
1:      j       1b

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
