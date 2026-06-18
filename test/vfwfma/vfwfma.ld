/* Phase 12 V3j widening FP FMA directed-test layout (flat image at DRAM
   0x80000000). The test is small (well under 4 KB), so tohost at 0x80001000
   sits clear of the code. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text) }

  . = 0x80001000;
  .tohost : { *(.tohost) }
}
