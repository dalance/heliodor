/* Bare-metal linker script for heliodor coremark.
   Text starts at PA 0x80000000 (DRAM base).
   .tohost pinned at PA 0x80008000 (word index 8192) so it stays clear of
   coremark's larger .text section (~6 KB). The tb harness must use
   matching TOHOST_IDX = 8192. */

OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS {
    . = 0x80000000;
    .text.init : { *(.text.init) }
    .text      : { *(.text .text.*) }

    . = 0x80008000;
    .tohost    : { *(.tohost) }

    . = 0x80008100;
    .rodata    : { *(.rodata .rodata.*) }
    .data      : { *(.data .data.*) }
    .sdata     : {
        __global_pointer$ = . + 0x800;
        *(.srodata .srodata.*)
        *(.sdata .sdata.*)
    }
    /* __bss_start covers BOTH .sbss and .bss so start.S zeros all of them.
     * Without this, seed{1,2,5}_volatile (which GCC places in .sbss because
     * they are zero-initialized) keep their DRAM-default values and the
     * "validation run" seed-check in coremark's main() picks up garbage. */
    __bss_start = .;
    .sbss      : { *(.sbss .sbss.*) }
    .bss       : {
        *(.bss .bss.*)
    }
    __bss_end = .;

    . = ALIGN(16);
    _heap_start = .;
    _end = .;

    /* Stack at top of 256 KB region */
    _stack_top = 0x80040000;
}
