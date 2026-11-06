// MI: Smcsrind/Sscsrind, Smcdeleg/Ssccfg and Ssqosid. Each access runs in
// one mode and is followed by an ECALL; the M handler records the first trap
// cause (2 illegal, 22 virtual, or the ECALL's 8, 9, 10 when the access did
// not trap). Each sub-case s that misbehaves stops with tohost
// (s << 8) | 0x42; tohost is 1 when all pass.
//   1 miselect, siselect and vsiselect hold 12 bits
//   2 sireg with siselect 0x43 is illegal without menvcfg.CDE, and with
//     CDE while mcounteren[3] is clear
//   3 delegated: sireg is mhpmcounter3, sireg2 is mhpmevent3 with MINH
//     read-only zero (a write keeps it), sireg with 0x40 is mcycle
//   4 illegal from M: sireg with 0x41, sireg2 with 0x40 (no Smcntrpmf),
//     sireg3-6, a siselect outside 0x40-0x5F, mireg, vsireg
//   5 HS: mstateen0.CSRIND gates siselect; sireg reaches the counter;
//     scountinhibit is illegal without CDE (also in M) and reads zero with it
//   6 VS: hstateen0.CSRIND clear makes siselect virtual; set, siselect is
//     vsiselect; sireg is virtual with CDE and illegal without it or outside
//     the window (virtual again with hstateen0.CSRIND clear); vsiselect and
//     vsireg are virtual; VU siselect is virtual; mstateen0.CSRIND clear makes
//     VS siselect illegal
//   7 VS: scountinhibit and scountovf are virtual with CDE; without CDE
//     scountinhibit is illegal and scountovf readable
//   8 srmcfg keeps RCID and MCID (12 bits each); mstateen0.SRMCFG gates S
//     and VS; V = 1 accesses are virtual; U is illegal
#include "common/probe.h"

#define MPV     (1 << 39)
#define CDE     (1 << 60)
#define CSRIND  (1 << 60)
#define SRMCFGB (1 << 55)
#define MINH    (1 << 62)
#define SINH    (1 << 61)
#define C_ILL   2
#define C_VIRT  22
#define E_U     8
#define E_S     9
#define E_VS    10
#define NONE    -1

.macro FAIL sub
    li      t0, (\sub << 8) | 0x42
    REPORT_REG t0
.endm

.macro EXPECT sub, val
    li      t0, \val
    beq     a0, t0, .Lok\@
    FAIL    \sub
.Lok\@:
.endm

.macro EXPECT_REG sub, reg, val
    li      t0, \val
    beq     \reg, t0, .Lok\@
    FAIL    \sub
.Lok\@:
.endm

// Run insn in M; a0 = its trap cause, or -1.
.macro TRY_M insn:vararg
    li      a0, NONE
    la      t0, trap_cause
    sd      a0, 0(t0)
    la      t5, .Lr\@
    la      t6, trap_resume
    sd      t5, 0(t6)
    \insn
.Lr\@:
    ld      a0, trap_cause
.endm

// Run insn with MPP = mpp and MPV = mpv, then ECALL; a0 = the first cause.
.macro TRY mpp, mpv, insn:vararg
    la      t5, .Lr\@
    la      t6, trap_resume
    sd      t5, 0(t6)
    li      t0, MSTATUS_MPP | MPV
    csrc    mstatus, t0
    li      t0, (\mpp << 11) | (\mpv << 39)
    csrs    mstatus, t0
    la      t0, .Lc\@
    csrw    mepc, t0
    mret
.Lc\@:
    \insn
    ecall
.Lr\@:
    ld      a0, trap_cause
.endm

    .section .text
main:
    // 1
    li      t1, -1
    csrw    0x350, t1
    csrw    0x150, t1
    csrw    0x250, t1
    csrr    a0, 0x350
    EXPECT  1, 0xfff
    csrr    a0, 0x150
    EXPECT  1, 0xfff
    csrr    a0, 0x250
    EXPECT  1, 0xfff
    li      t1, 0x1043
    csrw    0x150, t1
    csrr    a0, 0x150
    EXPECT  1, 0x43

    // 2
    csrw    mhpmevent3, zero
    TRY_M   csrr t1, 0x151
    EXPECT  2, C_ILL
    li      t1, CDE
    csrs    menvcfg, t1
    csrw    mcounteren, zero
    TRY_M   csrr t1, 0x151
    EXPECT  2, C_ILL

    // 3
    li      t1, -1
    csrw    mcounteren, t1
    li      t1, 0x1234
    TRY_M   csrw 0x151, t1
    EXPECT  3, NONE
    csrr    t1, mhpmcounter3
    EXPECT_REG 3, t1, 0x1234
    li      t1, 0
    TRY_M   csrr t1, 0x151
    EXPECT  3, NONE
    EXPECT_REG 3, t1, 0x1234
    li      t1, MINH
    csrw    mhpmevent3, t1
    li      t1, -1
    TRY_M   csrr t1, 0x152
    EXPECT  3, NONE
    EXPECT_REG 3, t1, 0
    li      t1, SINH
    TRY_M   csrw 0x152, t1
    EXPECT  3, NONE
    csrr    t1, mhpmevent3
    EXPECT_REG 3, t1, MINH | SINH
    csrw    mhpmevent3, zero
    li      t1, 0x40
    csrw    0x150, t1
    li      t1, 0x10000000
    TRY_M   csrw 0x151, t1
    EXPECT  3, NONE
    csrr    t2, mcycle
    li      t1, 0x10000000
    sub     t2, t2, t1
    li      t1, 0x1000
    bltu    t2, t1, 1f
    FAIL    3
1:

    // 4
    li      t1, 0x41
    csrw    0x150, t1
    TRY_M   csrr t1, 0x151
    EXPECT  4, C_ILL
    li      t1, 0x40
    csrw    0x150, t1
    TRY_M   csrr t1, 0x152
    EXPECT  4, C_ILL
    li      t1, 0x43
    csrw    0x150, t1
    TRY_M   csrr t1, 0x153
    EXPECT  4, C_ILL
    TRY_M   csrr t1, 0x155
    EXPECT  4, C_ILL
    TRY_M   csrr t1, 0x156
    EXPECT  4, C_ILL
    TRY_M   csrr t1, 0x157
    EXPECT  4, C_ILL
    TRY_M   csrr t1, 0x351
    EXPECT  4, C_ILL
    li      t1, 0x43
    csrw    0x250, t1
    TRY_M   csrr t1, 0x251
    EXPECT  4, C_ILL
    li      t1, 0x60
    csrw    0x150, t1
    TRY_M   csrr t1, 0x151
    EXPECT  4, C_ILL

    // 5
    li      t1, 0x43
    csrw    0x150, t1
    li      t1, 0x55
    csrw    mhpmcounter3, t1
    csrw    mstateen0, zero
    TRY     1, 0, csrr t1, 0x150
    EXPECT  5, C_ILL
    li      t1, CSRIND
    csrs    mstateen0, t1
    TRY     1, 0, csrr t1, 0x150
    EXPECT  5, E_S
    EXPECT_REG 5, t1, 0x43
    TRY     1, 0, csrr t1, 0x151
    EXPECT  5, E_S
    EXPECT_REG 5, t1, 0x55
    TRY     0, 0, csrr t1, 0x150
    EXPECT  5, C_ILL
    li      t1, CDE
    csrc    menvcfg, t1
    TRY     1, 0, csrr t1, 0x120
    EXPECT  5, C_ILL
    TRY_M   csrr t1, 0x120
    EXPECT  5, C_ILL
    li      t1, CDE
    csrs    menvcfg, t1
    li      t1, -1
    TRY     1, 0, csrrw t1, 0x120, t1
    EXPECT  5, E_S
    csrr    t1, 0x120
    EXPECT_REG 5, t1, 0

    // 6
    csrw    hstateen0, zero
    TRY     1, 1, csrr t1, 0x150
    EXPECT  6, C_VIRT
    li      t1, CSRIND
    csrs    hstateen0, t1
    li      t1, 0x55
    csrw    0x250, t1
    TRY     1, 1, csrr t1, 0x150
    EXPECT  6, E_VS
    EXPECT_REG 6, t1, 0x55
    li      t1, 0x42
    csrw    0x150, t1
    li      t1, 0x43
    TRY     1, 1, csrw 0x150, t1
    EXPECT  6, E_VS
    csrr    t1, 0x250
    EXPECT_REG 6, t1, 0x43
    csrr    t1, 0x150
    EXPECT_REG 6, t1, 0x42
    TRY     1, 1, csrr t1, 0x151
    EXPECT  6, C_VIRT
    li      t1, CDE
    csrc    menvcfg, t1
    TRY     1, 1, csrr t1, 0x151
    EXPECT  6, C_ILL
    li      t1, CDE
    csrs    menvcfg, t1
    li      t1, 0x60
    csrw    0x250, t1
    TRY     1, 1, csrr t1, 0x151
    EXPECT  6, C_ILL
    li      t1, CSRIND
    csrc    hstateen0, t1
    TRY     1, 1, csrr t1, 0x151
    EXPECT  6, C_VIRT
    TRY     1, 1, csrr t1, 0x250
    EXPECT  6, C_VIRT
    TRY     1, 1, csrr t1, 0x251
    EXPECT  6, C_VIRT
    TRY     0, 1, csrr t1, 0x150
    EXPECT  6, C_VIRT
    li      t1, CSRIND
    csrc    mstateen0, t1
    TRY     1, 1, csrr t1, 0x150
    EXPECT  6, C_ILL

    // 7
    TRY     1, 1, csrr t1, 0x120
    EXPECT  7, C_VIRT
    TRY     1, 1, csrr t1, 0xda0
    EXPECT  7, C_VIRT
    li      t1, CDE
    csrc    menvcfg, t1
    TRY     1, 1, csrr t1, 0x120
    EXPECT  7, C_ILL
    li      t1, -1
    csrw    hcounteren, t1
    TRY     1, 1, csrr t1, 0xda0
    EXPECT  7, E_VS

    // 8
    li      t1, -1
    csrw    0x181, t1
    csrr    a0, 0x181
    EXPECT  8, 0x0fff0fff
    TRY     1, 0, csrr t1, 0x181
    EXPECT  8, C_ILL
    TRY     1, 1, csrr t1, 0x181
    EXPECT  8, C_ILL
    li      t1, SRMCFGB
    csrs    mstateen0, t1
    TRY     1, 0, csrr t1, 0x181
    EXPECT  8, E_S
    EXPECT_REG 8, t1, 0x0fff0fff
    TRY     1, 1, csrr t1, 0x181
    EXPECT  8, C_VIRT
    TRY     0, 1, csrr t1, 0x181
    EXPECT  8, C_VIRT
    TRY     0, 0, csrr t1, 0x181
    EXPECT  8, C_ILL
    REPORT  1
