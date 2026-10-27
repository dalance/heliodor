// Debug ROM of the Debug Module (dm_mem). Position independent: it reaches
// the DM data region at a fixed +0x1000 from its own base, so it runs at any
// DM_BASE. Offsets match dm_pkg.
//
// A hart enters at +0x000 (halt and Debug Mode ebreak) or +0x004 (exception
// in Debug Mode). It saves s0/s1 in dscratch0/1, reports HALTED with its
// hartid and polls its flag byte: GO jumps to the abstract command program,
// RESUME leaves with dret. Both restore s0/s1 and run fence.i first, so the
// hart refetches whatever the debugger changed while it was halted. The
// exception entry relies on s0/s1 holding the hart's values when the fault
// is taken, which the abstract command program guarantees (dm_abs).

#define CSR_DCSR      0x7b0
#define CSR_DSCRATCH0 0x7b2
#define CSR_DSCRATCH1 0x7b3
#define MPRVEN        0x10

#define HALTED      0x100
#define GOING       0x104
#define RESUMING    0x108
#define EXCEPTION   0x10c
#define FLAGS       0x400
#define FLAG_GO     1
#define FLAG_RESUME 2
#define ABS_OFF     0x300

// Run the accesses with dcsr.mprven clear, so mstatus.MPRV cannot move them
// out of M-mode physical addressing, then put mprven back. s0 is clobbered.
#define NO_MPRV(...)                    \
        csrrci s0, CSR_DCSR, MPRVEN;    \
        andi   s0, s0, MPRVEN;          \
        bnez   s0, 1f;                  \
        __VA_ARGS__;                    \
        j      2f;                      \
1:      __VA_ARGS__;                    \
        csrsi  CSR_DCSR, MPRVEN;        \
2:

        .option norvc
        .option norelax
        .section .text
        .globl  entry
        .set    data, entry + 0x1000
entry:
        j       _entry
exception:
        j       _exception

_entry:
        fence
        csrw    CSR_DSCRATCH0, s0
        csrw    CSR_DSCRATCH1, s1
base0:  auipc   s1, %pcrel_hi(data)
        addi    s1, s1, %pcrel_lo(base0)
entry_loop:
        NO_MPRV(csrr s0, mhartid; sw s0, HALTED(s1); add s0, s0, s1; lbu s0, FLAGS(s0))
        andi    s0, s0, FLAG_GO
        bnez    s0, going
        NO_MPRV(csrr s0, mhartid; add s0, s0, s1; lbu s0, FLAGS(s0))
        andi    s0, s0, FLAG_RESUME
        bnez    s0, resume
        j       entry_loop

// GOING carries the hart's dcsr.mprven: the abstract command program runs
// its debug memory accesses with mprven clear and sets it back from this.
going:
        csrrci  s0, CSR_DCSR, MPRVEN
        andi    s0, s0, MPRVEN
        sw      s0, GOING(s1)
        beqz    s0, 1f
        csrsi   CSR_DCSR, MPRVEN
1:      csrr    s0, CSR_DSCRATCH0
        csrr    s1, CSR_DSCRATCH1
        fence.i
        j       entry + ABS_OFF

resume:
        NO_MPRV(csrr s0, mhartid; sw s0, RESUMING(s1))
        csrr    s0, CSR_DSCRATCH0
        csrr    s1, CSR_DSCRATCH1
        fence.i
        dret

_exception:
        csrw    CSR_DSCRATCH0, s0
        csrw    CSR_DSCRATCH1, s1
base1:  auipc   s1, %pcrel_hi(data)
        addi    s1, s1, %pcrel_lo(base1)
        NO_MPRV(sw zero, EXCEPTION(s1))
        csrr    s0, CSR_DSCRATCH0
        csrr    s1, CSR_DSCRATCH1
        j       _entry
