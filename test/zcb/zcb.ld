/* P10 Zcb directed-test layout (flat image at DRAM base 0x80000000).
 *
 *   0x80000000  .text     code (M-mode entry at _start) + databuf
 *   0x80001000  .tohost   riscv-tests tohost word (TOHOST_IDX 1024)
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text) }

  . = 0x80001000;
  .tohost : { *(.tohost) }
}
