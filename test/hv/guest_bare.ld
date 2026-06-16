/* Bare-metal guest: linked at guest-physical 0x80200000 (its load address,
 * mapped by the hypervisor G-stage to host 0x80600000). */
OUTPUT_ARCH("riscv")
ENTRY(_start)
SECTIONS {
    . = 0x80200000;
    .text.init : { *(.text.init) }
    .text      : { *(.text .text.*) }
    .rodata    : { *(.rodata .rodata.*) }
}
