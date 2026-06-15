/* P10 system-bundle (Zawrs/Svinval) directed-test layout.
 *
 *   0x80000000  .text     M-mode code
 *   0x80001000  .tohost   riscv-tests tohost word (TOHOST_IDX 1024)
 *   0x80010000+ runtime Sv39 page tables + data pages (written by the program)
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
