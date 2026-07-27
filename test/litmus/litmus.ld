/* P9.0 RVWMO litmus-test program layout.
 *
 * Everything (code + tohost + shared data) lives in one flat binary starting
 * at DRAM base 0x80000000 so the whole image — including the zero-initialized
 * barrier/vars/result/scratch areas — is loaded by $readmemh before any hart
 * runs (no runtime BSS-clear race between harts).
 *
 *   0x80000000  .text     code (all harts enter at _start)
 *   0x80001000  .tohost   riscv-tests tohost/fromhost (TOHOST_IDX 1024)
 *   0x80004000  .result   outcome histogram: word[test*16 + slot]
 *   0x80005000  .scratch  cross-hart result handoff (SB / IRIW)
 *   0x80006000  .barrier  barrier count @+0x00, sense @+0x40 (separate lines)
 *   0x80007000  .vars     litmus variables x @+0x00, y @+0x40 (separate lines)
 *
 * NOTE (R3 §7.1, 2026-07-27): .barrier and .vars USED to sit at 0x80002000 /
 * 0x80003000, inside the core's non-cacheable tohost window (ac_wexcl_q excludes
 * PA[31:14]==0x20000, i.e. 0x80000000-0x80003FFF). Every litmus atomic was therefore
 * a write-THROUGH access, so the battery never exercised the in-cache MESI atomic
 * path at all — the very path Test 7 is supposed to guard. Keep these sections at or
 * above 0x80004000.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
  . = 0x80000000;
  .text : { *(.text.init) *(.text) }

  . = 0x80001000;
  .tohost  : { *(.tohost) }
  .result  0x80004000 : { *(.result) }
  .scratch 0x80005000 : { *(.scratch) }
  .barrier 0x80006000 : { *(.barrier) }
  .vars    0x80007000 : { *(.vars) }
}
