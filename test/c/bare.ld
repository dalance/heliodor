/* Flat bare-metal linker script for heliodor RV64 processor */
/* Everything at 0x0000, no ROM/RAM split. Stack at 0x8000. */

ENTRY(_start)

MEMORY {
    MEM (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
}

SECTIONS {
    .text : {
        *(.text.start)
        *(.text .text.*)
    } > MEM

    .rodata : {
        *(.rodata .rodata.*)
        . = ALIGN(8);
    } > MEM

    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
        . = ALIGN(8);
    } > MEM

    .bss : {
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        . = ALIGN(8);
        _bss_end = .;
    } > MEM

    _stack_top = ORIGIN(MEM) + LENGTH(MEM);
}
