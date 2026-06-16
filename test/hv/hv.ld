/* Phase 11-H5.2b HS-mode hypervisor: linked at host DRAM 0x80000000 (the S-mode
 * entry the firmware jumps to). Code/data/stacks live in the low 4 MiB; the guest
 * RAM (mapped by the G-stage) starts at host 0x80400000. */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS {
    . = 0x80000000;
    .text.init : { *(.text.init) }
    .text      : { *(.text .text.*) }
    .rodata    : { *(.rodata .rodata.*) }
    .data      : { *(.data .data.*) }
    .sdata     : {
        __global_pointer$ = . + 0x800;
        *(.srodata .srodata.*)
        *(.sdata .sdata.*)
    }
    . = ALIGN(16);
    _bss_start = .;
    .sbss      : { *(.sbss .sbss.*) }
    .bss       : { *(.bss .bss.*) }
    . = ALIGN(16);
    _bss_end = .;

    /* Boot stack top (grows down). Trap stack top is 0x80018000 (hv_start.S). */
    _stack_top = 0x80010000;
}
