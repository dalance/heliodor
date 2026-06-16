ENTRY(_start)
MEMORY {
    ROM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
}
SECTIONS {
    .text : { *(.text.start) *(.text .text.*) } > ROM
    .rodata : { *(.rodata .rodata.*) } > ROM
    .data : { *(.data .data.*) } > ROM
    /DISCARD/ : { *(.comment) *(.note*) }
}
