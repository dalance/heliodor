/* Random instruction stream image (test/gr/gen.py), flat at DRAM 0x8000_0000:
 * entry and trap handler, tohost at 0x8000_1000 (TOHOST_IDX 1024), the
 * stream, then the data region page-aligned behind it.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text.init : { *(.text.init) }
  . = 0x80001000;
  .tohost : { *(.tohost) }
  . = 0x80002000;
  .text : { *(.text) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
}
