    .section ".text.init"
    .globl _start
_start:
    # Initialize global pointer. Linker relaxation rewrites the small-data
    # global accesses to gp-relative form (assuming gp == __global_pointer$),
    # so gp MUST be set up here — otherwise gp==0 sends every relaxed global
    # to a wild, often-misaligned address (e.g. End_Time -> gp-2009).
.option push
.option norelax
    la      gp, __global_pointer$
.option pop

    # Set stack pointer
    la      sp, _stack_top

    # Zero BSS
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sd      zero, 0(t0)
    addi    t0, t0, 8
    j       1b
2:
    # Enable FPU (FS=Initial)
    li      t0, 0x00006000
    csrs    mstatus, t0

    # Call main
    li      a0, 0
    li      a1, 0
    call    main

    # Exit: write 1 to tohost
    la      t0, tohost
    li      t1, 1
    sw      t1, 0(t0)
3:  j       3b
