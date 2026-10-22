/* Flat image at DRAM base: code at 0x80000000, tohost at 0x80003000,
 * shared barrier at 0x80006000 and shared data from 0x80007000. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text) }

  .tohost  0x80003000 : { *(.tohost) }
  .barrier 0x80006000 : { *(.barrier) }
  .vars    0x80007000 : { *(.vars) }
}
