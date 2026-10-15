/* Directed probe layout (flat image at DRAM base 0x80000000).
 *
 *   0x80000000  .text.init  entry, jumps to main
 *   0x80001000  .tohost     riscv-tests tohost word (TOHOST_IDX 1024)
 *   0x80002000  .text       probe code, trap handler, helpers
 *   0x80008000  .data       trap record and probe variables
 *   0x80010000              Sv39 page tables (built at run time)
 *   0x80020000              scratch data
 *   0x80200000              4 KiB pages mapped through the level-0 table
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

  . = 0x80008000;
  .data : { *(.data) *(.sdata) *(.bss) *(.sbss) }
}
