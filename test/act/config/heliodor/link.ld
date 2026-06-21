OUTPUT_ARCH( "riscv" )
ENTRY(rvtest_entry_point)

SECTIONS
{
  . = 0x80000000;
  .text.init    : { *(.text.init) }
  . = 0x80001000;
  .tohost       : { *(.tohost) }
  . = 0x80002000;
  .text.rvtest  : { *(.text.rvtest) *(.text.rvtest.*) }
  . = ALIGN(0x4000);
  .data         : { *(.data) }
  . = ALIGN(0x1000);
  .text.rvmodel : { *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*) }
  . = ALIGN(0x1000);
  _end = .;
}
