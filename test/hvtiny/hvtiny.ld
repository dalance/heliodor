/* Phase 11-H5.1 minimal type-1 hypervisor test layout (flat image at DRAM 0x80000000). */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text) }

  . = 0x80001000;
  .tohost : { *(.tohost) }
}
