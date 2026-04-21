/* Bare-metal linker script for heliodor riscv-tests benchmarks.
   Text starts at PA 0x80000000 (DRAM base).
   .tohost section at 0x80001000 for riscv-tests pass/fail signaling. */

OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS {
    . = 0x80000000;
    .text.init : { *(.text.init) }
    .text      : { *(.text .text.*) }

    . = ALIGN(0x1000);
    .tohost    : { *(.tohost) }

    . = ALIGN(16);
    .rodata    : { *(.rodata .rodata.*) }
    .data      : { *(.data .data.*) }
    .sdata     : {
        __global_pointer$ = . + 0x800;
        *(.srodata .srodata.*)
        *(.sdata .sdata.*)
    }
    .sbss      : { *(.sbss .sbss.*) }
    .bss       : {
        __bss_start = .;
        *(.bss .bss.*)
        __bss_end = .;
    }

    . = ALIGN(16);
    _heap_start = .;
    _end = .;

    /* Stack at top of 256 KB region */
    _stack_top = 0x80040000;
}
