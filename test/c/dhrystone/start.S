    .section ".text.init"
    .globl _start
_start:
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
