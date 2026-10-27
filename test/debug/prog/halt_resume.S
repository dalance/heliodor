# Hart program of dbg/halt_resume (dmi/halt_resume.dmi). Outside Debug Mode,
# dcsr, dpc, dscratch0/1 and DRET are illegal and debug memory faults like a
# hole (design doc D.8, D.14); EBREAK with dcsr.ebreakm = 0 is a breakpoint.
# Then a counting loop runs while the script halts and resumes the hart: its
# invariants catch a resume at a wrong pc and clobbered s0/s1/s2. tohost = 1
# on success, else the number of the failed check.

#define DM_CODE 0x4000
#define DM_DATA 0x5000
#define LOOP_N  40000

        .option norvc
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
        li      gp, 2

# a1 = expected mcause, a2 = where the handler resumes.
#define EXPECT(cause) li a1, cause; la a2, 9f
#define NO_TRAP       j fail; 9: addi gp, gp, 1

        EXPECT(2);  csrr t1, 0x7b0;          NO_TRAP    # dcsr
        EXPECT(2);  csrr t1, 0x7b1;          NO_TRAP    # dpc
        EXPECT(2);  csrw 0x7b2, t1;          NO_TRAP    # dscratch0
        EXPECT(2);  csrr t1, 0x7b3;          NO_TRAP    # dscratch1
        EXPECT(2);  .word 0x7b200073;        NO_TRAP    # dret
        li      t2, DM_DATA
        EXPECT(5);  lw t1, 0x100(t2);        NO_TRAP    # DM data load
        EXPECT(7);  sw t1, 0x100(t2);        NO_TRAP    # DM data store
        li      t2, DM_CODE
        EXPECT(5);  lw t1, 0(t2);            NO_TRAP    # DM code load
        EXPECT(1);  jr t2;                   NO_TRAP    # DM code fetch
        EXPECT(3);  ebreak;                  NO_TRAP    # dcsr.ebreakm = 0

        li      a1, -1
        li      s0, 0
        li      s1, 0
        li      s2, 0
        li      t2, LOOP_N
loop:   addi    s0, s0, 1
        addi    s1, s1, 2
        addi    s2, s2, 3
        bne     s0, t2, loop
        slli    t3, t2, 1
        bne     s1, t3, fail
        add     t3, t3, t2
        bne     s2, t3, fail

        li      gp, 1
fail:   la      t1, tohost
        sw      gp, 0(t1)
1:      j       1b

trap:   csrr    t0, mcause
        bne     t0, a1, fail
        csrw    mepc, a2
        mret

        .section .tohost, "aw"
        .align  6
        .globl  tohost
tohost: .dword  0
