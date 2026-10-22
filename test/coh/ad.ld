/* Flat image at DRAM base: code at 0x80000000, tohost at 0x80003000,
 * shared barrier at 0x80006000, page tables from 0x80010000 (the PTE
 * constants in ad.S assume this address) and test pages from 0x80020000. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text) }

  .tohost  0x80003000 : { *(.tohost) }
  .barrier 0x80006000 : { *(.barrier) }
  .pt      0x80010000 : { *(.pt) }
}
