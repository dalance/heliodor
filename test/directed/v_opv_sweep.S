// OP-V and vector load/store encodings: which execute and which trap.
//
// Each row is one instruction word run with SEW 32, LMUL 1, vl 2 (vd v10
// or v8, vs2 v16, vs1 v24; scalar operands x24/f24; memory rows use base
// s1, stride a6 and the zero index vector v16). A defined encoding the
// vector unit implements (EX) must not trap; a reserved encoding (TR) and a
// defined encoding the vector unit does not implement (NI) must raise an
// illegal-instruction exception. The sweep handler records the mcause of
// each trapping row and resumes at the next one, so a row that wedges shows
// as a timeout (tohost 0).
// tohost: 1, or 0x10000 + the index of the first row whose outcome differs
// (each such row prints i=<index> and c=<0x80 | mcause, or 0>).
#include "common/probe.h"

#define OPIVV 0
#define OPFVV 1
#define OPMVV 2
#define OPIVI 3
#define OPIVX 4
#define OPFVF 5
#define OPMVX 6
#define LOAD  0x07
#define STORE 0x27

.macro ROW exp, word
    .word   \word
    .pushsection .data
    .byte   \exp
    .popsection
.endm

.macro OPV exp, f6, f3, vm, vs2, vs1, vd
    ROW     \exp, (((\f6) << 26) | ((\vm) << 25) | ((\vs2) << 20) | ((\vs1) << 15) | ((\f3) << 12) | ((\vd) << 7) | 0x57)
.endm

.macro EX f6, f3, vm=1, vs2=16, vs1=24, vd=10
    OPV     0, \f6, \f3, \vm, \vs2, \vs1, \vd
.endm

.macro TR f6, f3, vm=1, vs2=16, vs1=24, vd=10
    OPV     0x82, \f6, \f3, \vm, \vs2, \vs1, \vd
.endm

.macro NI f6, f3, vm=1, vs2=16, vs1=24, vd=10
    OPV     0x82, \f6, \f3, \vm, \vs2, \vs1, \vd
.endm

// opc, nf, mew, mop, vm, lumop/rs2/vs2, width; data register v8, base s1.
.macro VMEM exp, opc, nf, mew, mop, vm, rs2, w
    ROW     \exp, (((\nf) << 29) | ((\mew) << 28) | ((\mop) << 26) | ((\vm) << 25) | ((\rs2) << 20) | (9 << 15) | ((\w) << 12) | (8 << 7) | (\opc))
.endm

.macro EXM opc, nf, mew, mop, vm, rs2, w
    VMEM    0, \opc, \nf, \mew, \mop, \vm, \rs2, \w
.endm

.macro TRM opc, nf, mew, mop, vm, rs2, w
    VMEM    0x82, \opc, \nf, \mew, \mop, \vm, \rs2, \w
.endm

.macro NIM opc, nf, mew, mop, vm, rs2, w
    VMEM    0x82, \opc, \nf, \mew, \mop, \vm, \rs2, \w
.endm

    .section .data
exp_tab:

    .section .text
main:
    li      t0, MSTATUS_VS_INIT | MSTATUS_FS_INIT
    csrs    mstatus, t0
    vsetivli zero, 4, e32, m1, tu, mu
    vmv.v.i v0, 3
    vmv.v.i v16, 0
    vmv.v.i v17, 0
    vmv.v.i v24, 1
    vsetivli zero, 2, e32, m1, tu, mu
    li      s1, SCRATCH
    li      a6, 4
    li      s8, 1
    fmv.w.x f24, s8
    la      s10, sweep
    la      s11, res_tab
    la      t0, sweep_trap
    csrw    mtvec, t0
    j       sweep

    .align 2
sweep_trap:
    csrr    t5, mepc
    sub     t6, t5, s10
    srli    t6, t6, 2
    add     t6, t6, s11
    addi    t5, t5, 4
    csrw    mepc, t5
    csrr    t5, mcause
    ori     t5, t5, 0x80
    sb      t5, 0(t6)
    csrw    vstart, zero
    mret

    .align 2
sweep:

    // OPIVV
    EX  0x00, OPIVV                         // vadd.vv
    EX  0x01, OPIVV                         // vandn.vv
    EX  0x02, OPIVV                         // vsub.vv
    TR  0x03, OPIVV                         // reserved
    EX  0x04, OPIVV                         // vminu.vv
    EX  0x05, OPIVV                         // vmin.vv
    EX  0x06, OPIVV                         // vmaxu.vv
    EX  0x07, OPIVV                         // vmax.vv
    TR  0x08, OPIVV                         // reserved
    EX  0x09, OPIVV                         // vand.vv
    EX  0x0a, OPIVV                         // vor.vv
    EX  0x0b, OPIVV                         // vxor.vv
    EX  0x0c, OPIVV                         // vrgather.vv
    TR  0x0d, OPIVV                         // reserved
    EX  0x0e, OPIVV                         // vrgatherei16.vv
    TR  0x0f, OPIVV                         // reserved
    EX  0x14, OPIVV                         // vror.vv
    EX  0x15, OPIVV                         // vrol.vv
    TR  0x16, OPIVV                         // reserved
    EX  0x18, OPIVV                         // vmseq.vv
    EX  0x19, OPIVV                         // vmsne.vv
    EX  0x1a, OPIVV                         // vmsltu.vv
    EX  0x1b, OPIVV                         // vmslt.vv
    EX  0x1c, OPIVV                         // vmsleu.vv
    EX  0x1d, OPIVV                         // vmsle.vv
    TR  0x1e, OPIVV                         // reserved
    TR  0x1f, OPIVV                         // reserved
    EX  0x20, OPIVV                         // vsaddu.vv
    EX  0x21, OPIVV                         // vsadd.vv
    EX  0x22, OPIVV                         // vssubu.vv
    EX  0x23, OPIVV                         // vssub.vv
    TR  0x24, OPIVV                         // reserved
    EX  0x25, OPIVV                         // vsll.vv
    TR  0x26, OPIVV                         // reserved
    EX  0x27, OPIVV                         // vsmul.vv
    EX  0x28, OPIVV                         // vsrl.vv
    EX  0x29, OPIVV                         // vsra.vv
    EX  0x2a, OPIVV                         // vssrl.vv
    EX  0x2b, OPIVV                         // vssra.vv
    EX  0x2c, OPIVV                         // vnsrl.wv
    EX  0x2d, OPIVV                         // vnsra.wv
    EX  0x2e, OPIVV                         // vnclipu.wv
    EX  0x2f, OPIVV                         // vnclip.wv
    EX  0x30, OPIVV                         // vwredsumu.vs
    EX  0x31, OPIVV                         // vwredsum.vs
    TR  0x32, OPIVV                         // reserved
    TR  0x33, OPIVV                         // reserved
    TR  0x34, OPIVV                         // reserved
    EX  0x35, OPIVV                         // vwsll.vv
    TR  0x36, OPIVV                         // reserved
    TR  0x37, OPIVV                         // reserved
    TR  0x38, OPIVV                         // reserved
    TR  0x39, OPIVV                         // reserved
    TR  0x3a, OPIVV                         // reserved
    TR  0x3b, OPIVV                         // reserved
    TR  0x3c, OPIVV                         // reserved
    TR  0x3d, OPIVV                         // reserved
    TR  0x3e, OPIVV                         // reserved
    TR  0x3f, OPIVV                         // reserved
    EX  0x10, OPIVV, vm=0                   // vadc.vvm
    TR  0x10, OPIVV                         // vadc with vm = 1: reserved
    EX  0x11, OPIVV, vm=0                   // vmadc.vvm
    EX  0x11, OPIVV                         // vmadc.vv
    EX  0x12, OPIVV, vm=0                   // vsbc.vvm
    TR  0x12, OPIVV                         // vsbc with vm = 1: reserved
    EX  0x13, OPIVV, vm=0                   // vmsbc.vvm
    EX  0x13, OPIVV                         // vmsbc.vv
    EX  0x17, OPIVV, vm=0                   // vmerge.vvm
    EX  0x17, OPIVV, vs2=0                  // vmv.v.v
    TR  0x17, OPIVV                         // vmv.v.v with vs2 != 0: reserved

    // OPIVX
    EX  0x00, OPIVX                         // vadd.vx
    EX  0x01, OPIVX                         // vandn.vx
    EX  0x02, OPIVX                         // vsub.vx
    EX  0x03, OPIVX                         // vrsub.vx
    EX  0x04, OPIVX                         // vminu.vx
    EX  0x05, OPIVX                         // vmin.vx
    EX  0x06, OPIVX                         // vmaxu.vx
    EX  0x07, OPIVX                         // vmax.vx
    TR  0x08, OPIVX                         // reserved
    EX  0x09, OPIVX                         // vand.vx
    EX  0x0a, OPIVX                         // vor.vx
    EX  0x0b, OPIVX                         // vxor.vx
    EX  0x0c, OPIVX                         // vrgather.vx
    TR  0x0d, OPIVX                         // reserved
    EX  0x0e, OPIVX                         // vslideup.vx
    EX  0x0f, OPIVX                         // vslidedown.vx
    EX  0x14, OPIVX                         // vror.vx
    EX  0x15, OPIVX                         // vrol.vx
    TR  0x16, OPIVX                         // reserved
    EX  0x18, OPIVX                         // vmseq.vx
    EX  0x19, OPIVX                         // vmsne.vx
    EX  0x1a, OPIVX                         // vmsltu.vx
    EX  0x1b, OPIVX                         // vmslt.vx
    EX  0x1c, OPIVX                         // vmsleu.vx
    EX  0x1d, OPIVX                         // vmsle.vx
    EX  0x1e, OPIVX                         // vmsgtu.vx
    EX  0x1f, OPIVX                         // vmsgt.vx
    EX  0x20, OPIVX                         // vsaddu.vx
    EX  0x21, OPIVX                         // vsadd.vx
    EX  0x22, OPIVX                         // vssubu.vx
    EX  0x23, OPIVX                         // vssub.vx
    TR  0x24, OPIVX                         // reserved
    EX  0x25, OPIVX                         // vsll.vx
    TR  0x26, OPIVX                         // reserved
    EX  0x27, OPIVX                         // vsmul.vx
    EX  0x28, OPIVX                         // vsrl.vx
    EX  0x29, OPIVX                         // vsra.vx
    EX  0x2a, OPIVX                         // vssrl.vx
    EX  0x2b, OPIVX                         // vssra.vx
    EX  0x2c, OPIVX                         // vnsrl.wx
    EX  0x2d, OPIVX                         // vnsra.wx
    EX  0x2e, OPIVX                         // vnclipu.wx
    EX  0x2f, OPIVX                         // vnclip.wx
    TR  0x30, OPIVX                         // reserved
    TR  0x31, OPIVX                         // reserved
    TR  0x32, OPIVX                         // reserved
    TR  0x33, OPIVX                         // reserved
    TR  0x34, OPIVX                         // reserved
    EX  0x35, OPIVX                         // vwsll.vx
    TR  0x36, OPIVX                         // reserved
    TR  0x37, OPIVX                         // reserved
    TR  0x38, OPIVX                         // reserved
    TR  0x39, OPIVX                         // reserved
    TR  0x3a, OPIVX                         // reserved
    TR  0x3b, OPIVX                         // reserved
    TR  0x3c, OPIVX                         // reserved
    TR  0x3d, OPIVX                         // reserved
    TR  0x3e, OPIVX                         // reserved
    TR  0x3f, OPIVX                         // reserved
    EX  0x10, OPIVX, vm=0                   // vadc.vxm
    TR  0x10, OPIVX                         // vadc with vm = 1: reserved
    EX  0x11, OPIVX, vm=0                   // vmadc.vxm
    EX  0x11, OPIVX                         // vmadc.vx
    EX  0x12, OPIVX, vm=0                   // vsbc.vxm
    TR  0x12, OPIVX                         // vsbc with vm = 1: reserved
    EX  0x13, OPIVX, vm=0                   // vmsbc.vxm
    EX  0x13, OPIVX                         // vmsbc.vx
    EX  0x17, OPIVX, vm=0                   // vmerge.vxm
    EX  0x17, OPIVX, vs2=0                  // vmv.v.x
    TR  0x17, OPIVX                         // vmv.v.x with vs2 != 0: reserved

    // OPIVI
    EX  0x00, OPIVI                         // vadd.vi
    TR  0x01, OPIVI                         // reserved
    TR  0x02, OPIVI                         // reserved
    EX  0x03, OPIVI                         // vrsub.vi
    TR  0x04, OPIVI                         // reserved
    TR  0x05, OPIVI                         // reserved
    TR  0x06, OPIVI                         // reserved
    TR  0x07, OPIVI                         // reserved
    TR  0x08, OPIVI                         // reserved
    EX  0x09, OPIVI                         // vand.vi
    EX  0x0a, OPIVI                         // vor.vi
    EX  0x0b, OPIVI                         // vxor.vi
    EX  0x0c, OPIVI                         // vrgather.vi
    TR  0x0d, OPIVI                         // reserved
    EX  0x0e, OPIVI                         // vslideup.vi
    EX  0x0f, OPIVI                         // vslidedown.vi
    TR  0x12, OPIVI                         // reserved
    TR  0x13, OPIVI                         // reserved
    EX  0x14, OPIVI                         // vror.vi
    EX  0x15, OPIVI                         // vror.vi (uimm bit 5 set)
    TR  0x16, OPIVI                         // reserved
    EX  0x18, OPIVI                         // vmseq.vi
    EX  0x19, OPIVI                         // vmsne.vi
    TR  0x1a, OPIVI                         // reserved
    TR  0x1b, OPIVI                         // reserved
    EX  0x1c, OPIVI                         // vmsleu.vi
    EX  0x1d, OPIVI                         // vmsle.vi
    EX  0x1e, OPIVI                         // vmsgtu.vi
    EX  0x1f, OPIVI                         // vmsgt.vi
    EX  0x20, OPIVI                         // vsaddu.vi
    EX  0x21, OPIVI                         // vsadd.vi
    TR  0x22, OPIVI                         // reserved
    TR  0x23, OPIVI                         // reserved
    TR  0x24, OPIVI                         // reserved
    EX  0x25, OPIVI                         // vsll.vi
    TR  0x26, OPIVI                         // reserved
    EX  0x28, OPIVI                         // vsrl.vi
    EX  0x29, OPIVI                         // vsra.vi
    EX  0x2a, OPIVI                         // vssrl.vi
    EX  0x2b, OPIVI                         // vssra.vi
    EX  0x2c, OPIVI                         // vnsrl.wi
    EX  0x2d, OPIVI                         // vnsra.wi
    EX  0x2e, OPIVI                         // vnclipu.wi
    EX  0x2f, OPIVI                         // vnclip.wi
    TR  0x30, OPIVI                         // reserved
    TR  0x31, OPIVI                         // reserved
    TR  0x32, OPIVI                         // reserved
    TR  0x33, OPIVI                         // reserved
    TR  0x34, OPIVI                         // reserved
    EX  0x35, OPIVI                         // vwsll.vi
    TR  0x36, OPIVI                         // reserved
    TR  0x37, OPIVI                         // reserved
    TR  0x38, OPIVI                         // reserved
    TR  0x39, OPIVI                         // reserved
    TR  0x3a, OPIVI                         // reserved
    TR  0x3b, OPIVI                         // reserved
    TR  0x3c, OPIVI                         // reserved
    TR  0x3d, OPIVI                         // reserved
    TR  0x3e, OPIVI                         // reserved
    TR  0x3f, OPIVI                         // reserved
    EX  0x10, OPIVI, vm=0                   // vadc.vim
    TR  0x10, OPIVI                         // vadc with vm = 1: reserved
    EX  0x11, OPIVI, vm=0                   // vmadc.vim
    EX  0x11, OPIVI                         // vmadc.vi
    EX  0x17, OPIVI, vm=0                   // vmerge.vim
    EX  0x17, OPIVI, vs2=0                  // vmv.v.i
    TR  0x17, OPIVI                         // vmv.v.i with vs2 != 0: reserved
    EX  0x27, OPIVI, vs1=0, vd=8            // vmv1r.v
    EX  0x27, OPIVI, vs1=1, vd=8            // vmv2r.v
    EX  0x27, OPIVI, vs1=3, vd=8            // vmv4r.v
    EX  0x27, OPIVI, vs1=7, vd=8            // vmv8r.v
    TR  0x27, OPIVI, vs1=2, vd=8            // vmv<nr>r.v with nr = 3: reserved

    // OPMVV
    EX  0x00, OPMVV                         // vredsum.vs
    EX  0x01, OPMVV                         // vredand.vs
    EX  0x02, OPMVV                         // vredor.vs
    EX  0x03, OPMVV                         // vredxor.vs
    EX  0x04, OPMVV                         // vredminu.vs
    EX  0x05, OPMVV                         // vredmin.vs
    EX  0x06, OPMVV                         // vredmaxu.vs
    EX  0x07, OPMVV                         // vredmax.vs
    EX  0x08, OPMVV                         // vaaddu.vv
    EX  0x09, OPMVV                         // vaadd.vv
    EX  0x0a, OPMVV                         // vasubu.vv
    EX  0x0b, OPMVV                         // vasub.vv
    TR  0x0c, OPMVV                         // reserved
    TR  0x0d, OPMVV                         // reserved
    TR  0x0e, OPMVV                         // reserved
    TR  0x0f, OPMVV                         // reserved
    TR  0x11, OPMVV                         // reserved
    TR  0x13, OPMVV                         // reserved
    TR  0x15, OPMVV                         // reserved
    TR  0x16, OPMVV                         // reserved
    EX  0x20, OPMVV                         // vdivu.vv
    EX  0x21, OPMVV                         // vdiv.vv
    EX  0x22, OPMVV                         // vremu.vv
    EX  0x23, OPMVV                         // vrem.vv
    EX  0x24, OPMVV                         // vmulhu.vv
    EX  0x25, OPMVV                         // vmul.vv
    EX  0x26, OPMVV                         // vmulhsu.vv
    EX  0x27, OPMVV                         // vmulh.vv
    TR  0x28, OPMVV                         // reserved
    EX  0x29, OPMVV                         // vmadd.vv
    TR  0x2a, OPMVV                         // reserved
    EX  0x2b, OPMVV                         // vnmsub.vv
    TR  0x2c, OPMVV                         // reserved
    EX  0x2d, OPMVV                         // vmacc.vv
    TR  0x2e, OPMVV                         // reserved
    EX  0x2f, OPMVV                         // vnmsac.vv
    EX  0x30, OPMVV                         // vwaddu.vv
    EX  0x31, OPMVV                         // vwadd.vv
    EX  0x32, OPMVV                         // vwsubu.vv
    EX  0x33, OPMVV                         // vwsub.vv
    EX  0x34, OPMVV                         // vwaddu.wv
    EX  0x35, OPMVV                         // vwadd.wv
    EX  0x36, OPMVV                         // vwsubu.wv
    EX  0x37, OPMVV                         // vwsub.wv
    EX  0x38, OPMVV                         // vwmulu.vv
    TR  0x39, OPMVV                         // reserved
    EX  0x3a, OPMVV                         // vwmulsu.vv
    EX  0x3b, OPMVV                         // vwmul.vv
    EX  0x3c, OPMVV                         // vwmaccu.vv
    EX  0x3d, OPMVV                         // vwmacc.vv
    TR  0x3e, OPMVV                         // reserved
    EX  0x3f, OPMVV                         // vwmaccsu.vv
    EX  0x10, OPMVV, vs1=0                  // vmv.x.s
    TR  0x10, OPMVV, vm=0, vs1=0            // vmv.x.s with vm = 0: reserved
    EX  0x10, OPMVV, vs1=16                 // vcpop.m
    EX  0x10, OPMVV, vs1=17                 // vfirst.m
    TR  0x10, OPMVV, vs1=1                  // VWXUNARY0 vs1 = 1: reserved
    TR  0x12, OPMVV, vs1=2                  // vzext.vf8 at SEW 32 (EEW 4): reserved
    TR  0x12, OPMVV, vs1=3                  // vsext.vf8 at SEW 32 (EEW 4): reserved
    EX  0x12, OPMVV, vs1=4                  // vzext.vf4
    EX  0x12, OPMVV, vs1=5                  // vsext.vf4
    EX  0x12, OPMVV, vs1=6                  // vzext.vf2
    EX  0x12, OPMVV, vs1=7                  // vsext.vf2
    TR  0x12, OPMVV, vs1=0                  // VXUNARY0 vs1 = 0: reserved
    EX  0x12, OPMVV, vs1=8                  // vbrev8.v
    EX  0x12, OPMVV, vs1=9                  // vrev8.v
    EX  0x12, OPMVV, vs1=10                 // vbrev.v
    TR  0x12, OPMVV, vs1=11                 // VXUNARY0 vs1 = 11: reserved
    EX  0x12, OPMVV, vs1=12                 // vclz.v
    EX  0x12, OPMVV, vs1=13                 // vctz.v
    EX  0x12, OPMVV, vs1=14                 // vcpop.v
    TR  0x12, OPMVV, vs1=15                 // VXUNARY0 vs1 = 15: reserved
    EX  0x14, OPMVV, vs1=1                  // vmsbf.m
    EX  0x14, OPMVV, vs1=2                  // vmsof.m
    EX  0x14, OPMVV, vs1=3                  // vmsif.m
    EX  0x14, OPMVV, vs1=16                 // viota.m
    EX  0x14, OPMVV, vs2=0, vs1=17          // vid.v
    TR  0x14, OPMVV, vs1=0                  // VMUNARY0 vs1 = 0: reserved
    TR  0x14, OPMVV, vs1=17                 // vid.v with vs2 != 0: reserved
    EX  0x17, OPMVV                         // vcompress.vm
    TR  0x17, OPMVV, vm=0                   // vcompress with vm = 0: reserved
    EX  0x18, OPMVV                         // vmandn.mm
    EX  0x19, OPMVV                         // vmand.mm
    EX  0x1a, OPMVV                         // vmor.mm
    EX  0x1b, OPMVV                         // vmxor.mm
    EX  0x1c, OPMVV                         // vmorn.mm
    EX  0x1d, OPMVV                         // vmnand.mm
    EX  0x1e, OPMVV                         // vmnor.mm
    EX  0x1f, OPMVV                         // vmxnor.mm
    TR  0x19, OPMVV, vm=0                   // vmand with vm = 0: reserved

    // OPMVX
    TR  0x00, OPMVX                         // reserved
    TR  0x01, OPMVX                         // reserved
    TR  0x02, OPMVX                         // reserved
    TR  0x03, OPMVX                         // reserved
    TR  0x04, OPMVX                         // reserved
    TR  0x05, OPMVX                         // reserved
    TR  0x06, OPMVX                         // reserved
    TR  0x07, OPMVX                         // reserved
    EX  0x08, OPMVX                         // vaaddu.vx
    EX  0x09, OPMVX                         // vaadd.vx
    EX  0x0a, OPMVX                         // vasubu.vx
    EX  0x0b, OPMVX                         // vasub.vx
    TR  0x0c, OPMVX                         // reserved
    TR  0x0d, OPMVX                         // reserved
    EX  0x0e, OPMVX                         // vslide1up.vx
    EX  0x0f, OPMVX                         // vslide1down.vx
    TR  0x11, OPMVX                         // reserved
    TR  0x12, OPMVX                         // reserved
    TR  0x13, OPMVX                         // reserved
    TR  0x14, OPMVX                         // reserved
    TR  0x15, OPMVX                         // reserved
    TR  0x16, OPMVX                         // reserved
    TR  0x17, OPMVX                         // reserved
    TR  0x18, OPMVX                         // reserved
    TR  0x19, OPMVX                         // reserved
    TR  0x1a, OPMVX                         // reserved
    TR  0x1b, OPMVX                         // reserved
    TR  0x1c, OPMVX                         // reserved
    TR  0x1d, OPMVX                         // reserved
    TR  0x1e, OPMVX                         // reserved
    TR  0x1f, OPMVX                         // reserved
    EX  0x20, OPMVX                         // vdivu.vx
    EX  0x21, OPMVX                         // vdiv.vx
    EX  0x22, OPMVX                         // vremu.vx
    EX  0x23, OPMVX                         // vrem.vx
    EX  0x24, OPMVX                         // vmulhu.vx
    EX  0x25, OPMVX                         // vmul.vx
    EX  0x26, OPMVX                         // vmulhsu.vx
    EX  0x27, OPMVX                         // vmulh.vx
    TR  0x28, OPMVX                         // reserved
    EX  0x29, OPMVX                         // vmadd.vx
    TR  0x2a, OPMVX                         // reserved
    EX  0x2b, OPMVX                         // vnmsub.vx
    TR  0x2c, OPMVX                         // reserved
    EX  0x2d, OPMVX                         // vmacc.vx
    TR  0x2e, OPMVX                         // reserved
    EX  0x2f, OPMVX                         // vnmsac.vx
    EX  0x30, OPMVX                         // vwaddu.vx
    EX  0x31, OPMVX                         // vwadd.vx
    EX  0x32, OPMVX                         // vwsubu.vx
    EX  0x33, OPMVX                         // vwsub.vx
    EX  0x34, OPMVX                         // vwaddu.wx
    EX  0x35, OPMVX                         // vwadd.wx
    EX  0x36, OPMVX                         // vwsubu.wx
    EX  0x37, OPMVX                         // vwsub.wx
    EX  0x38, OPMVX                         // vwmulu.vx
    TR  0x39, OPMVX                         // reserved
    EX  0x3a, OPMVX                         // vwmulsu.vx
    EX  0x3b, OPMVX                         // vwmul.vx
    EX  0x3c, OPMVX                         // vwmaccu.vx
    EX  0x3d, OPMVX                         // vwmacc.vx
    EX  0x3e, OPMVX                         // vwmaccus.vx
    EX  0x3f, OPMVX                         // vwmaccsu.vx
    EX  0x10, OPMVX, vs2=0                  // vmv.s.x
    TR  0x10, OPMVX                         // VRXUNARY0 vs2 != 0: reserved

    // OPFVV
    EX  0x00, OPFVV                         // vfadd.vv
    EX  0x01, OPFVV                         // vfredusum.vs
    EX  0x02, OPFVV                         // vfsub.vv
    EX  0x03, OPFVV                         // vfredosum.vs
    EX  0x04, OPFVV                         // vfmin.vv
    EX  0x05, OPFVV                         // vfredmin.vs
    EX  0x06, OPFVV                         // vfmax.vv
    EX  0x07, OPFVV                         // vfredmax.vs
    EX  0x08, OPFVV                         // vfsgnj.vv
    EX  0x09, OPFVV                         // vfsgnjn.vv
    EX  0x0a, OPFVV                         // vfsgnjx.vv
    TR  0x0b, OPFVV                         // reserved
    TR  0x0c, OPFVV                         // reserved
    TR  0x0d, OPFVV                         // reserved
    TR  0x0e, OPFVV                         // reserved
    TR  0x0f, OPFVV                         // reserved
    TR  0x11, OPFVV                         // reserved
    TR  0x14, OPFVV                         // reserved
    TR  0x15, OPFVV                         // reserved
    TR  0x16, OPFVV                         // reserved
    TR  0x17, OPFVV                         // reserved
    EX  0x18, OPFVV                         // vmfeq.vv
    EX  0x19, OPFVV                         // vmfle.vv
    TR  0x1a, OPFVV                         // reserved
    EX  0x1b, OPFVV                         // vmflt.vv
    EX  0x1c, OPFVV                         // vmfne.vv
    TR  0x1d, OPFVV                         // reserved
    TR  0x1e, OPFVV                         // reserved
    TR  0x1f, OPFVV                         // reserved
    EX  0x20, OPFVV                         // vfdiv.vv
    TR  0x21, OPFVV                         // reserved
    TR  0x22, OPFVV                         // reserved
    TR  0x23, OPFVV                         // reserved
    EX  0x24, OPFVV                         // vfmul.vv
    TR  0x25, OPFVV                         // reserved
    TR  0x26, OPFVV                         // reserved
    TR  0x27, OPFVV                         // reserved
    EX  0x28, OPFVV                         // vfmadd.vv
    EX  0x29, OPFVV                         // vfnmadd.vv
    EX  0x2a, OPFVV                         // vfmsub.vv
    EX  0x2b, OPFVV                         // vfnmsub.vv
    EX  0x2c, OPFVV                         // vfmacc.vv
    EX  0x2d, OPFVV                         // vfnmacc.vv
    EX  0x2e, OPFVV                         // vfmsac.vv
    EX  0x2f, OPFVV                         // vfnmsac.vv
    EX  0x30, OPFVV                         // vfwadd.vv
    EX  0x31, OPFVV                         // vfwredusum.vs
    EX  0x32, OPFVV                         // vfwsub.vv
    EX  0x33, OPFVV                         // vfwredosum.vs
    EX  0x34, OPFVV                         // vfwadd.wv
    TR  0x35, OPFVV                         // reserved
    EX  0x36, OPFVV                         // vfwsub.wv
    TR  0x37, OPFVV                         // reserved
    EX  0x38, OPFVV                         // vfwmul.vv
    TR  0x39, OPFVV                         // reserved
    TR  0x3a, OPFVV                         // reserved
    TR  0x3b, OPFVV                         // reserved
    EX  0x3c, OPFVV                         // vfwmacc.vv
    EX  0x3d, OPFVV                         // vfwnmacc.vv
    EX  0x3e, OPFVV                         // vfwmsac.vv
    EX  0x3f, OPFVV                         // vfwnmsac.vv
    EX  0x10, OPFVV, vs1=0                  // vfmv.f.s
    TR  0x10, OPFVV, vm=0, vs1=0            // vfmv.f.s with vm = 0: reserved
    TR  0x10, OPFVV, vs1=1                  // VWFUNARY0 vs1 = 1: reserved
    EX  0x12, OPFVV, vs1=0                  // vfcvt.xu.f.v
    EX  0x12, OPFVV, vs1=1                  // vfcvt.x.f.v
    EX  0x12, OPFVV, vs1=2                  // vfcvt.f.xu.v
    EX  0x12, OPFVV, vs1=3                  // vfcvt.f.x.v
    TR  0x12, OPFVV, vs1=4                  // VFUNARY0: reserved
    TR  0x12, OPFVV, vs1=5                  // VFUNARY0: reserved
    EX  0x12, OPFVV, vs1=6                  // vfcvt.rtz.xu.f.v
    EX  0x12, OPFVV, vs1=7                  // vfcvt.rtz.x.f.v
    EX  0x12, OPFVV, vs1=8                  // vfwcvt.xu.f.v
    EX  0x12, OPFVV, vs1=9                  // vfwcvt.x.f.v
    EX  0x12, OPFVV, vs1=10                 // vfwcvt.f.xu.v
    EX  0x12, OPFVV, vs1=11                 // vfwcvt.f.x.v
    EX  0x12, OPFVV, vs1=12                 // vfwcvt.f.f.v
    TR  0x12, OPFVV, vs1=13                 // VFUNARY0: reserved
    EX  0x12, OPFVV, vs1=14                 // vfwcvt.rtz.xu.f.v
    EX  0x12, OPFVV, vs1=15                 // vfwcvt.rtz.x.f.v
    EX  0x12, OPFVV, vs1=16                 // vfncvt.xu.f.w
    EX  0x12, OPFVV, vs1=17                 // vfncvt.x.f.w
    EX  0x12, OPFVV, vs1=18                 // vfncvt.f.xu.w
    EX  0x12, OPFVV, vs1=19                 // vfncvt.f.x.w
    EX  0x12, OPFVV, vs1=20                 // vfncvt.f.f.w
    EX  0x12, OPFVV, vs1=21                 // vfncvt.rod.f.f.w
    EX  0x12, OPFVV, vs1=22                 // vfncvt.rtz.xu.f.w
    EX  0x12, OPFVV, vs1=23                 // vfncvt.rtz.x.f.w
    TR  0x12, OPFVV                         // VFUNARY0: reserved
    TR  0x12, OPFVV, vs1=25                 // VFUNARY0: reserved
    TR  0x12, OPFVV, vs1=26                 // VFUNARY0: reserved
    TR  0x12, OPFVV, vs1=27                 // VFUNARY0: reserved
    TR  0x12, OPFVV, vs1=28                 // VFUNARY0: reserved
    TR  0x12, OPFVV, vs1=29                 // VFUNARY0: reserved
    TR  0x12, OPFVV, vs1=30                 // VFUNARY0: reserved
    TR  0x12, OPFVV, vs1=31                 // VFUNARY0: reserved
    EX  0x13, OPFVV, vs1=0                  // vfsqrt.v
    TR  0x13, OPFVV, vs1=1                  // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=2                  // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=3                  // VFUNARY1: reserved
    EX  0x13, OPFVV, vs1=4                  // vfrsqrt7.v
    EX  0x13, OPFVV, vs1=5                  // vfrec7.v
    TR  0x13, OPFVV, vs1=6                  // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=7                  // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=8                  // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=9                  // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=10                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=11                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=12                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=13                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=14                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=15                 // VFUNARY1: reserved
    EX  0x13, OPFVV, vs1=16                 // vfclass.v
    TR  0x13, OPFVV, vs1=17                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=18                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=19                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=20                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=21                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=22                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=23                 // VFUNARY1: reserved
    TR  0x13, OPFVV                         // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=25                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=26                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=27                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=28                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=29                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=30                 // VFUNARY1: reserved
    TR  0x13, OPFVV, vs1=31                 // VFUNARY1: reserved

    // OPFVF
    EX  0x00, OPFVF                         // vfadd.vf
    TR  0x01, OPFVF                         // reserved
    EX  0x02, OPFVF                         // vfsub.vf
    TR  0x03, OPFVF                         // reserved
    EX  0x04, OPFVF                         // vfmin.vf
    TR  0x05, OPFVF                         // reserved
    EX  0x06, OPFVF                         // vfmax.vf
    TR  0x07, OPFVF                         // reserved
    EX  0x08, OPFVF                         // vfsgnj.vf
    EX  0x09, OPFVF                         // vfsgnjn.vf
    EX  0x0a, OPFVF                         // vfsgnjx.vf
    TR  0x0b, OPFVF                         // reserved
    TR  0x0c, OPFVF                         // reserved
    TR  0x0d, OPFVF                         // reserved
    EX  0x0e, OPFVF                         // vfslide1up.vf
    EX  0x0f, OPFVF                         // vfslide1down.vf
    TR  0x11, OPFVF                         // reserved
    TR  0x12, OPFVF                         // reserved
    TR  0x13, OPFVF                         // reserved
    TR  0x14, OPFVF                         // reserved
    TR  0x15, OPFVF                         // reserved
    TR  0x16, OPFVF                         // reserved
    EX  0x18, OPFVF                         // vmfeq.vf
    EX  0x19, OPFVF                         // vmfle.vf
    TR  0x1a, OPFVF                         // reserved
    EX  0x1b, OPFVF                         // vmflt.vf
    EX  0x1c, OPFVF                         // vmfne.vf
    EX  0x1d, OPFVF                         // vmfgt.vf
    TR  0x1e, OPFVF                         // reserved
    EX  0x1f, OPFVF                         // vmfge.vf
    EX  0x20, OPFVF                         // vfdiv.vf
    EX  0x21, OPFVF                         // vfrdiv.vf
    TR  0x22, OPFVF                         // reserved
    TR  0x23, OPFVF                         // reserved
    EX  0x24, OPFVF                         // vfmul.vf
    TR  0x25, OPFVF                         // reserved
    TR  0x26, OPFVF                         // reserved
    EX  0x27, OPFVF                         // vfrsub.vf
    EX  0x28, OPFVF                         // vfmadd.vf
    EX  0x29, OPFVF                         // vfnmadd.vf
    EX  0x2a, OPFVF                         // vfmsub.vf
    EX  0x2b, OPFVF                         // vfnmsub.vf
    EX  0x2c, OPFVF                         // vfmacc.vf
    EX  0x2d, OPFVF                         // vfnmacc.vf
    EX  0x2e, OPFVF                         // vfmsac.vf
    EX  0x2f, OPFVF                         // vfnmsac.vf
    EX  0x30, OPFVF                         // vfwadd.vf
    TR  0x31, OPFVF                         // reserved
    EX  0x32, OPFVF                         // vfwsub.vf
    TR  0x33, OPFVF                         // reserved
    EX  0x34, OPFVF                         // vfwadd.wf
    TR  0x35, OPFVF                         // reserved
    EX  0x36, OPFVF                         // vfwsub.wf
    TR  0x37, OPFVF                         // reserved
    EX  0x38, OPFVF                         // vfwmul.vf
    TR  0x39, OPFVF                         // reserved
    TR  0x3a, OPFVF                         // reserved
    TR  0x3b, OPFVF                         // reserved
    EX  0x3c, OPFVF                         // vfwmacc.vf
    EX  0x3d, OPFVF                         // vfwnmacc.vf
    EX  0x3e, OPFVF                         // vfwmsac.vf
    EX  0x3f, OPFVF                         // vfwnmsac.vf
    EX  0x10, OPFVF, vs2=0                  // vfmv.s.f
    TR  0x10, OPFVF                         // VRFUNARY0 vs2 != 0: reserved
    TR  0x10, OPFVF, vm=0, vs2=0            // vfmv.s.f with vm = 0: reserved
    EX  0x17, OPFVF, vm=0                   // vfmerge.vfm
    EX  0x17, OPFVF, vs2=0                  // vfmv.v.f
    TR  0x17, OPFVF                         // vfmv.v.f with vs2 != 0: reserved

    // vector loads and stores (EEW 32, base s1, stride a6, index v16)
    EXM LOAD, 0, 0, 0, 1, 0, 6              // vle32.v
    EXM LOAD, 1, 0, 0, 1, 0, 6              // vlseg2e32.v
    EXM LOAD, 2, 0, 0, 1, 0, 6              // vlseg3e32.v
    EXM LOAD, 3, 0, 0, 1, 0, 6              // vlseg4e32.v
    EXM LOAD, 4, 0, 0, 1, 0, 6              // vlseg5e32.v
    EXM LOAD, 5, 0, 0, 1, 0, 6              // vlseg6e32.v
    EXM LOAD, 6, 0, 0, 1, 0, 6              // vlseg7e32.v
    EXM LOAD, 7, 0, 0, 1, 0, 6              // vlseg8e32.v
    EXM LOAD, 0, 0, 2, 1, 16, 6             // vlse32.v
    EXM LOAD, 0, 0, 1, 1, 16, 6             // vluxei32.v
    EXM LOAD, 0, 0, 3, 1, 16, 6             // vloxei32.v
    EXM LOAD, 1, 0, 2, 1, 16, 6             // vlsseg2e32.v
    EXM LOAD, 1, 0, 1, 1, 16, 6             // vluxseg2ei32.v
    EXM LOAD, 1, 0, 3, 1, 16, 6             // vloxseg2ei32.v
    EXM LOAD, 7, 0, 2, 1, 16, 6             // vlsseg8e32.v
    EXM LOAD, 7, 0, 1, 1, 16, 6             // vluxseg8ei32.v
    EXM LOAD, 7, 0, 3, 1, 16, 6             // vloxseg8ei32.v
    EXM LOAD, 0, 0, 0, 1, 11, 0             // vlm.v
    TRM LOAD, 0, 0, 0, 1, 11, 6             // vlm.v with EEW 32: reserved
    TRM LOAD, 1, 0, 0, 1, 11, 0             // vlm.v with nf = 1: reserved
    TRM LOAD, 0, 0, 0, 0, 11, 0             // vlm.v with vm = 0: reserved
    EXM LOAD, 0, 0, 0, 1, 8, 6              // vl1re32.v
    EXM LOAD, 1, 0, 0, 1, 8, 6              // vl2re32.v
    EXM LOAD, 3, 0, 0, 1, 8, 6              // vl4re32.v
    EXM LOAD, 7, 0, 0, 1, 8, 6              // vl8re32.v
    TRM LOAD, 0, 0, 0, 0, 8, 6              // vl1re32.v with vm = 0: reserved
    EXM LOAD, 0, 0, 0, 1, 16, 6             // vle32ff.v
    EXM LOAD, 1, 0, 0, 1, 16, 6             // vlseg2e32ff.v
    EXM LOAD, 7, 0, 0, 1, 16, 6             // vlseg8e32ff.v
    TRM LOAD, 2, 0, 0, 1, 8, 6              // vl3r: reserved
    TRM LOAD, 4, 0, 0, 1, 8, 6              // vl5r: reserved
    TRM LOAD, 5, 0, 0, 1, 8, 6              // vl6r: reserved
    TRM LOAD, 6, 0, 0, 1, 8, 6              // vl7r: reserved
    TRM LOAD, 0, 0, 0, 1, 1, 6              // vl lumop 00001: reserved
    TRM LOAD, 0, 1, 0, 1, 0, 6              // vle32.v with mew = 1: reserved
    EXM STORE, 0, 0, 0, 1, 0, 6             // vse32.v
    EXM STORE, 1, 0, 0, 1, 0, 6             // vsseg2e32.v
    EXM STORE, 2, 0, 0, 1, 0, 6             // vsseg3e32.v
    EXM STORE, 3, 0, 0, 1, 0, 6             // vsseg4e32.v
    EXM STORE, 4, 0, 0, 1, 0, 6             // vsseg5e32.v
    EXM STORE, 5, 0, 0, 1, 0, 6             // vsseg6e32.v
    EXM STORE, 6, 0, 0, 1, 0, 6             // vsseg7e32.v
    EXM STORE, 7, 0, 0, 1, 0, 6             // vsseg8e32.v
    EXM STORE, 0, 0, 2, 1, 16, 6            // vsse32.v
    EXM STORE, 0, 0, 1, 1, 16, 6            // vsuxei32.v
    EXM STORE, 0, 0, 3, 1, 16, 6            // vsoxei32.v
    EXM STORE, 1, 0, 2, 1, 16, 6            // vssseg2e32.v
    EXM STORE, 1, 0, 1, 1, 16, 6            // vsuxseg2ei32.v
    EXM STORE, 1, 0, 3, 1, 16, 6            // vsoxseg2ei32.v
    EXM STORE, 7, 0, 2, 1, 16, 6            // vssseg8e32.v
    EXM STORE, 7, 0, 1, 1, 16, 6            // vsuxseg8ei32.v
    EXM STORE, 7, 0, 3, 1, 16, 6            // vsoxseg8ei32.v
    EXM STORE, 0, 0, 0, 1, 11, 0            // vsm.v
    TRM STORE, 0, 0, 0, 1, 11, 6            // vsm.v with EEW 32: reserved
    TRM STORE, 1, 0, 0, 1, 11, 0            // vsm.v with nf = 1: reserved
    TRM STORE, 0, 0, 0, 0, 11, 0            // vsm.v with vm = 0: reserved
    EXM STORE, 0, 0, 0, 1, 8, 0             // vs1r.v
    EXM STORE, 1, 0, 0, 1, 8, 0             // vs2r.v
    EXM STORE, 3, 0, 0, 1, 8, 0             // vs4r.v
    EXM STORE, 7, 0, 0, 1, 8, 0             // vs8r.v
    TRM STORE, 0, 0, 0, 1, 8, 6             // vs1r.v with EEW 32: reserved
    TRM STORE, 0, 0, 0, 0, 8, 0             // vs1r.v with vm = 0: reserved
    TRM STORE, 0, 0, 0, 1, 16, 6            // unit-stride store lumop 10000: reserved
    TRM STORE, 2, 0, 0, 1, 8, 0             // vs3r: reserved
    TRM STORE, 4, 0, 0, 1, 8, 0             // vs5r: reserved
    TRM STORE, 5, 0, 0, 1, 8, 0             // vs6r: reserved
    TRM STORE, 6, 0, 0, 1, 8, 0             // vs7r: reserved
    TRM STORE, 0, 0, 0, 1, 1, 6             // vs lumop 00001: reserved
    TRM STORE, 0, 1, 0, 1, 0, 6             // vse32.v with mew = 1: reserved
sweep_end:
    la      t0, trap_entry
    csrw    mtvec, t0
    la      s2, exp_tab
    li      s3, 0                   // row index
    la      s4, sweep_end
    sub     s4, s4, s10
    srli    s4, s4, 2               // rows
    li      s5, -1                  // first mismatching row
1:  add     t0, s2, s3
    lbu     t1, 0(t0)
    add     t0, s11, s3
    lbu     t2, 0(t0)
    beq     t1, t2, 2f
    bgez    s5, 3f
    mv      s5, s3
3:  mv      s6, t2
    PRINT   'i', s3
    PRINT   'c', s6
2:  addi    s3, s3, 1
    bltu    s3, s4, 1b
    bgez    s5, fail
    REPORT  1
fail:
    li      t0, 0x10000
    add     t0, t0, s5
    REPORT_REG t0

    .section .data
res_tab:
    .space  1024
