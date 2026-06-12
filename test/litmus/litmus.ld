/* P9.0 RVWMO litmus-test program layout.
 *
 * Everything (code + tohost + shared data) lives in one flat binary starting
 * at DRAM base 0x80000000 so the whole image — including the zero-initialized
 * barrier/vars/result/scratch areas — is loaded by $readmemh before any hart
 * runs (no runtime BSS-clear race between harts).
 *
 *   0x80000000  .text     code (all harts enter at _start)
 *   0x80001000  .tohost   riscv-tests tohost/fromhost (TOHOST_IDX 1024)
 *   0x80002000  .barrier  barrier count @+0x00, sense @+0x40 (separate lines)
 *   0x80003000  .vars     litmus variables x @+0x00, y @+0x40 (separate lines)
 *   0x80004000  .result   outcome histogram: word[test*16 + slot]
 *   0x80005000  .scratch  cross-hart result handoff (SB / IRIW)
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text) }

  . = 0x80001000;
  .tohost  : { *(.tohost) }
  .barrier 0x80002000 : { *(.barrier) }
  .vars    0x80003000 : { *(.vars) }
  .result  0x80004000 : { *(.result) }
  .scratch 0x80005000 : { *(.scratch) }
}
