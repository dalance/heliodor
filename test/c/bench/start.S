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

    # Call main; main returns 0 on success, non-zero subtest id on failure.
    li      a0, 0
    li      a1, 0
    call    main

    # Encode tohost: pass = 1, fail = (subtest << 1) | 1.
    # Since a0=0 → (0<<1)|1 = 1 (pass). a0=n>0 → odd > 1 (fail).
    slli    a0, a0, 1
    ori     a0, a0, 1
    la      t0, tohost
    sw      a0, 0(t0)
3:  j       3b
