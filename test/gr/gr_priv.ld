/* Privileged random stream image (test/gr/gen.py --priv), flat at DRAM
 * 0x8000_0000; test/gr/priv.py hard-codes these addresses.
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
  ASSERT(. <= 0x80100000, "S code overflows into the U code pages")
  . = 0x80100000;
  .utext : { *(.utext) }
  ASSERT(. <= 0x80200000, "U code overflows into the data region")
  . = 0x80200000;
  .data : { *(.data) }
  ASSERT(. <= 0x80210000, "data overflows into the page tables")
  . = 0x80210000;
  .pt : { *(.pt) }
  ASSERT(. <= 0x80300000, "page tables overflow into the pool")
  . = 0x80300000;
  .pool : { *(.pool) }
}
