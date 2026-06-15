/* P10 Svadu directed-test layout (flat image at DRAM base 0x80000000). */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text) }

  . = 0x80001000;
  .tohost : { *(.tohost) }
}
