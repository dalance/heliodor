/* Bare-metal startup for heliodor RV64 processor */
    .section .text.start, "ax"
    .global _start
_start:
    /* Set up stack pointer */
    la sp, _stack_top

    /* Zero BSS section */
    la t0, _bss_start
    la t1, _bss_end
1:  bge t0, t1, 2f
    sd zero, 0(t0)
    addi t0, t0, 8
    j 1b
2:
    /* Call main */
    call main

    /* Infinite loop after main returns */
3:  j 3b
