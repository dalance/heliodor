/* DRAM image at 0x80000000 with tohost at 0x80001000 (word 1024). */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text) }
  .tohost 0x80001000 : { *(.tohost) }
}
