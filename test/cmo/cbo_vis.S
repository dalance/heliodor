# Visibility of cbo.clean/flush/inval to an agent outside the coherence
# domain: the tb reads and writes the DRAM behind the SoC's AXI port directly
# (BD_OPS of tb/test_cbo_vis.veryl), at fixed cycles after reset.
#
#   A  hart 0 stores, cbo.clean        the tb checks DRAM at CHK_CY
#   B  hart 0 stores, cbo.flush        the tb checks DRAM at CHK_CY
#   C  hart 0 loads (clean copy); the tb writes DRAM at POKE_CY; after
#      INV_CY hart 0 runs cbo.inval and must load the tb's value
# POKE_CY < INV_CY < CHK_CY: the program reports before the DRAM checks.
#   F  as C with cbo.flush, which must deallocate the clean copy
# With NHARTS = 2, hart 1 also takes part:
#   D  hart 1 stores (dirty in its L1), hart 0 cbo.flush   checked at CHK_CY
#   E  hart 1 stores (dirty in its L1), hart 0 cbo.clean   checked at CHK_CY
#   G  hart 1 loads (clean copy); the tb writes DRAM at POKE_CY; hart 0 runs
#      cbo.inval after INV_CY, then hart 1 must load the tb's value
#
# tohost = 1 | (stale << 1): bit 1 C, bit 2 F, bit 3 G stale after the CMO.
# A trap writes 0x99.

#define LINE_A  0x80000800
#define LINE_B  0x80000840
#define LINE_C  0x80000880
#define LINE_D  0x800008c0
#define LINE_E  0x80000900
#define LINE_F  0x80000940
#define LINE_G  0x80000980
#define FLAG1   0x800009c0
#define FLAG2   0x80000a00
#define DONE1   0x80000a40

#define INV_CY  25000

        .option norvc
        .option arch, +zicbom
        .section .text.init
        .globl _start
_start:
        la      t0, trap
        csrw    mtvec, t0
        csrr    s0, mhartid
        li      s2, 0
        bnez    s0, hart1

        li      s1, LINE_C
        ld      t1, 0(s1)
        li      s1, LINE_F
        ld      t1, 0(s1)

        li      s1, LINE_A
        li      t1, 0xa1a1a1a1a1a1a1a1
        sd      t1, 0(s1)
        cbo.clean (s1)
        li      s1, LINE_B
        li      t1, 0xb1b1b1b1b1b1b1b1
        sd      t1, 0(s1)
        cbo.flush (s1)
        fence   rw, rw

#if NHARTS == 2
        li      s1, FLAG1
1:      ld      t1, 0(s1)
        beqz    t1, 1b
        li      s1, LINE_D
        cbo.flush (s1)
        li      s1, LINE_E
        cbo.clean (s1)
        fence   rw, rw
#endif

        li      t2, INV_CY
2:      csrr    t1, mcycle
        bltu    t1, t2, 2b

        li      s1, LINE_C
        cbo.inval (s1)
        ld      t1, 0(s1)
        li      t2, 0xc2c2c2c2c2c2c2c2
        beq     t1, t2, 3f
        ori     s2, s2, 2
3:      li      s1, LINE_F
        cbo.flush (s1)
        ld      t1, 0(s1)
        li      t2, 0xf2f2f2f2f2f2f2f2
        beq     t1, t2, 4f
        ori     s2, s2, 4
4:

#if NHARTS == 2
        li      s1, LINE_G
        cbo.inval (s1)
        fence   rw, rw
        li      s1, FLAG2
        li      t1, 1
        sd      t1, 0(s1)
        li      s1, DONE1
5:      ld      t1, 0(s1)
        beqz    t1, 5b
        li      t2, 1
        beq     t1, t2, 6f
        ori     s2, s2, 8
6:
#endif
        slli    t1, s2, 1
        ori     t1, t1, 1
        j       report

hart1:
#if NHARTS == 2
        li      s1, LINE_G
        ld      t1, 0(s1)
        li      s1, LINE_D
        li      t1, 0xd1d1d1d1d1d1d1d1
        sd      t1, 0(s1)
        li      s1, LINE_E
        li      t1, 0xe1e1e1e1e1e1e1e1
        sd      t1, 0(s1)
        li      s1, FLAG1
        li      t1, 1
        sd      t1, 0(s1)
        li      s1, FLAG2
7:      ld      t1, 0(s1)
        beqz    t1, 7b
        li      s1, LINE_G
        ld      t1, 0(s1)
        li      t2, 0x6262626262626262
        li      t3, 1
        beq     t1, t2, 8f
        li      t3, 2
8:      li      s1, DONE1
        sd      t3, 0(s1)
#endif
9:      j       9b

trap:   li      t1, 0x99
report: la      t0, tohost
        sw      t1, 0(t0)
10:     j       10b

        .org    0x800
        .dword  0xa0a0a0a0a0a0a0a0, 0, 0, 0, 0, 0, 0, 0
        .dword  0xb0b0b0b0b0b0b0b0, 0, 0, 0, 0, 0, 0, 0
        .dword  0xc0c0c0c0c0c0c0c0, 0, 0, 0, 0, 0, 0, 0
        .dword  0xd0d0d0d0d0d0d0d0, 0, 0, 0, 0, 0, 0, 0
        .dword  0xe0e0e0e0e0e0e0e0, 0, 0, 0, 0, 0, 0, 0
        .dword  0xf0f0f0f0f0f0f0f0, 0, 0, 0, 0, 0, 0, 0
        .dword  0x6060606060606060, 0, 0, 0, 0, 0, 0, 0
        .dword  0, 0, 0, 0, 0, 0, 0, 0
        .dword  0, 0, 0, 0, 0, 0, 0, 0
        .dword  0, 0, 0, 0, 0, 0, 0, 0

        .section .tohost, "aw", @progbits
        .align  6
        .globl  tohost
tohost: .dword  0
