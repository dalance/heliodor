ENTRY(_start)
MEMORY {
    DRAM (rwx) : ORIGIN = 0x80000000, LENGTH = 4M
}
SECTIONS {
    .text : { *(.text.start) *(.text .text.*) } > DRAM
    .rodata : { *(.rodata .rodata.*) } > DRAM
    .data : { *(.data .data.*) } > DRAM
    .bss : { *(.bss .bss.*) } > DRAM
    /DISCARD/ : { *(.comment) *(.note*) }
}
