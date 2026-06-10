    .section ".text.init"
    .globl _start
_start:
    /* Global pointer — REQUIRED: gcc accesses .sdata/.sbss objects
     * (e.g. static_memblk, the seed variables) gp-relative via linker
     * relaxation. Without this, gp stays 0 and every small-data address
     * computes as a small negative number (the original "CoreMark never
     * reaches tohost" hang: matrix N read through a garbage pointer).
     * norelax keeps the la itself from being relaxed into a gp move. */
.option push
.option norelax
    la      gp, __global_pointer$
.option pop

    /* Stack pointer */
    la      sp, _stack_top

    /* Zero BSS */
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:
    /* Enable FPU (FS=Initial) — required since CoreMark may touch
     * the FP regfile via prologue saves even when HAS_FLOAT=0. */
    li      t0, 0x00006000
    csrs    mstatus, t0

    /* Call main */
    li      a0, 0
    li      a1, 0
    call    main

    /* Pass: write 1 to tohost (a0 = main's return value, normally 0) */
    la      t0, tohost
    li      t1, 1
    sd      t1, 0(t0)

3:  j 3b   /* spin */

    .section ".tohost", "aw", @progbits
    .globl tohost
tohost: .dword 0
