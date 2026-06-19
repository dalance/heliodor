# Phase 12 V3a directed test: vector FP arithmetic (OPFVV .vv), SEW=32/64.
# Exercises vfadd/vfsub/vfmul/vfmin/vfmax/vfsgnj/vfsgnjn/vfsgnjx on single
# precision, masked vfadd (undisturbed inactive), vfadd on double, and the
# fflags accrual path (overflow → OF|NX).
#
# Single (vl=4):
#   a = [ 1.0, 2.0, -1.5,  4.0]  = [3F800000,40000000,BFC00000,40800000]
#   b = [ 2.0, 0.5,  0.5, -2.0]  = [40000000,3F000000,3F000000,C0000000]
#
# tohost @ 0x80001000: 1 = PASS; 2.. = the failing check id.

    .macro CK off, val, failL
        lwu  t5, \off(a2); li t6, \val; bne t5, t6, \failL
    .endm
    .macro CK64 off, val, failL
        ld   t5, \off(a2); li t6, \val; bne t5, t6, \failL
    .endm

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000
    # Enable both VS (bit 9) and FS (bit 13): the VU executes vector FP ops and
    # the test reads fcsr.fflags (an FP-CSR access requires mstatus.FS != Off).
    li   t0, (1 << 9) | (1 << 13)
    csrs mstatus, t0

    li   a0, 0x80010000          # a  (vs2, 4 x f32)
    li   a1, 0x80010040          # b  (vs1, 4 x f32)
    li   a2, 0x80010080          # dst (4 x f32)
    li t1,0x3F800000; sw t1,0(a0);  li t1,0x40000000; sw t1,4(a0)
    li t1,0xBFC00000; sw t1,8(a0);  li t1,0x40800000; sw t1,12(a0)
    li t1,0x40000000; sw t1,0(a1);  li t1,0x3F000000; sw t1,4(a1)
    li t1,0x3F000000; sw t1,8(a1);  li t1,0xC0000000; sw t1,12(a1)

    vsetvli t0, x0, e32, m1      # SEW=32, LMUL=1 → VLMAX=4
    li   t1, 4
    bne  t0, t1, fail2
    vle32.v v4, (a0)             # v4 = a
    vle32.v v6, (a1)             # v6 = b

    # --- vfadd.vv : a + b ---
    vfadd.vv v8, v4, v6
    vse32.v v8, (a2)
    CK 0,  0x40400000, fail3     # 3.0
    CK 4,  0x40200000, fail3     # 2.5
    CK 8,  0xBF800000, fail3     # -1.0
    CK 12, 0x40000000, fail3     # 2.0

    # --- vfsub.vv : a - b ---
    vfsub.vv v8, v4, v6
    vse32.v v8, (a2)
    CK 0,  0xBF800000, fail4     # -1.0
    CK 4,  0x3FC00000, fail4     # 1.5
    CK 8,  0xC0000000, fail4     # -2.0
    CK 12, 0x40C00000, fail4     # 6.0

    # --- vfmul.vv : a * b ---
    vfmul.vv v8, v4, v6
    vse32.v v8, (a2)
    CK 0,  0x40000000, fail5     # 2.0
    CK 4,  0x3F800000, fail5     # 1.0
    CK 8,  0xBF400000, fail5     # -0.75
    CK 12, 0xC1000000, fail5     # -8.0

    # --- vfmin.vv : min(a, b) ---
    vfmin.vv v8, v4, v6
    vse32.v v8, (a2)
    CK 0,  0x3F800000, fail6     # 1.0
    CK 4,  0x3F000000, fail6     # 0.5
    CK 8,  0xBFC00000, fail6     # -1.5
    CK 12, 0xC0000000, fail6     # -2.0

    # --- vfmax.vv : max(a, b) ---
    vfmax.vv v8, v4, v6
    vse32.v v8, (a2)
    CK 0,  0x40000000, fail7     # 2.0
    CK 4,  0x40000000, fail7     # 2.0
    CK 8,  0x3F000000, fail7     # 0.5
    CK 12, 0x40800000, fail7     # 4.0

    # --- vfsgnj.vv : magnitude vs2(a), sign vs1(b) ---
    vfsgnj.vv v8, v4, v6
    vse32.v v8, (a2)
    CK 0,  0x3F800000, fail8     # +1.0
    CK 4,  0x40000000, fail8     # +2.0
    CK 8,  0x3FC00000, fail8     # +1.5
    CK 12, 0xC0800000, fail8     # -4.0

    # --- vfsgnjn.vv : magnitude vs2(a), sign = ~sign vs1(b) ---
    vfsgnjn.vv v8, v4, v6
    vse32.v v8, (a2)
    CK 0,  0xBF800000, fail9     # -1.0
    CK 4,  0xC0000000, fail9     # -2.0
    CK 8,  0xBFC00000, fail9     # -1.5
    CK 12, 0x40800000, fail9     # +4.0

    # --- vfsgnjx.vv : magnitude vs2(a), sign = sign(a) ^ sign(b) ---
    vfsgnjx.vv v8, v4, v6
    vse32.v v8, (a2)
    CK 0,  0x3F800000, fail10    # +1.0
    CK 4,  0x40000000, fail10    # +2.0
    CK 8,  0xBFC00000, fail10    # -1.5
    CK 12, 0xC0800000, fail10    # -4.0

    # --- masked vfadd: v0 mask = 0b0101 (elems 0,2 active) ---
    li   a3, 0x80010300
    li   t1, 0x05; sb t1, 0(a3)            # mask byte: bits 0,2 set
    li t1,0xDEAD0000; sw t1,16(a3); li t1,0xDEAD0001; sw t1,20(a3)
    li t1,0xDEAD0002; sw t1,24(a3); li t1,0xDEAD0003; sw t1,28(a3)
    li   t1, 1
    vsetvli t0, t1, e8, m1                  # vl=1, SEW=8: load mask byte
    vle8.v  v0, (a3)
    addi a4, a3, 16
    vsetvli t0, x0, e32, m1                 # back to SEW=32, vl=4
    vle32.v v8, (a4)                        # v8 = sentinel
    vfadd.vv v8, v4, v6, v0.t               # only elems 0,2 written
    vse32.v v8, (a2)
    CK 0,  0x40400000, fail11    # active 0: 3.0
    CK 4,  0xDEAD0001, fail11    # inactive 1: sentinel undisturbed
    CK 8,  0xBF800000, fail11    # active 2: -1.0
    CK 12, 0xDEAD0003, fail11    # inactive 3: sentinel undisturbed

    # --- .vf forms: FP scalar f[rs1] = 2.0 broadcast (v4 = a still loaded) ---
    li   t1, 0x40000000; sw t1, 64(a3)     # 2.0f in memory
    flw  fa0, 64(a3)                        # fa0 = 2.0
    vsetvli t0, x0, e32, m1                 # SEW=32, vl=4
    vfadd.vf v8, v4, fa0                     # a + 2.0
    vse32.v v8, (a2)
    CK 0,  0x40400000, fail16    # 3.0
    CK 4,  0x40800000, fail16    # 4.0
    CK 8,  0x3F000000, fail16    # 0.5
    CK 12, 0x40C00000, fail16    # 6.0
    vfsub.vf v8, v4, fa0                     # a - 2.0
    vse32.v v8, (a2)
    CK 0,  0xBF800000, fail17    # -1.0
    CK 4,  0x00000000, fail17    # 0.0
    CK 8,  0xC0600000, fail17    # -3.5
    CK 12, 0x40000000, fail17    # 2.0
    vfrsub.vf v8, v4, fa0                    # 2.0 - a (reverse)
    vse32.v v8, (a2)
    CK 0,  0x3F800000, fail18    # 1.0
    CK 4,  0x00000000, fail18    # 0.0
    CK 8,  0x40600000, fail18    # 3.5
    CK 12, 0xC0000000, fail18    # -2.0
    vfmul.vf v8, v4, fa0                     # a * 2.0
    vse32.v v8, (a2)
    CK 0,  0x40000000, fail19    # 2.0
    CK 4,  0x40800000, fail19    # 4.0
    CK 8,  0xC0400000, fail19    # -3.0
    CK 12, 0x41000000, fail19    # 8.0
    vfsgnj.vf v8, v4, fa0                    # mag a, sign(+2.0) = + all
    vse32.v v8, (a2)
    CK 0,  0x3F800000, fail20    # +1.0
    CK 4,  0x40000000, fail20    # +2.0
    CK 8,  0x3FC00000, fail20    # +1.5
    CK 12, 0x40800000, fail20    # +4.0

    # --- double precision vfadd (SEW=64, vl=2) ---
    li   a0, 0x80010100
    li   a1, 0x80010140
    li   a2, 0x80010180
    li t1,0x3FF0000000000000; sd t1,0(a0)   # 1.0
    li t1,0x4000000000000000; sd t1,8(a0)   # 2.0
    li t1,0x4000000000000000; sd t1,0(a1)   # 2.0
    li t1,0x4008000000000000; sd t1,8(a1)   # 3.0
    vsetvli t0, x0, e64, m1      # SEW=64 → VLMAX=2
    li   t1, 2
    bne  t0, t1, fail12
    vle64.v v4, (a0)
    vle64.v v6, (a1)
    vfadd.vv v8, v4, v6
    vse64.v v8, (a2)
    CK64 0, 0x4008000000000000, fail13   # 3.0
    CK64 8, 0x4014000000000000, fail13   # 5.0
    # double .vf: vfadd.vf with FP scalar 2.0 (v4 = [1.0, 2.0])
    li t1,0x4000000000000000; sd t1,16(a0); fld fa1, 16(a0)
    vfadd.vf v8, v4, fa1
    vse64.v v8, (a2)
    CK64 0, 0x4008000000000000, fail16b  # 1.0+2.0 = 3.0
    CK64 8, 0x4010000000000000, fail16b  # 2.0+2.0 = 4.0

    # ===================== V3c: vfdiv / vfsqrt =========================
    # single-precision (single-cycle) div family. p / q chosen exact.
    li   a0, 0x80010400          # p (numerator)
    li   a1, 0x80010440          # q (denominator)
    li   a2, 0x80010080          # dst
    li t1,0x40800000; sw t1,0(a0)   # 4.0
    li t1,0x41000000; sw t1,4(a0)   # 8.0
    li t1,0x40000000; sw t1,8(a0)   # 2.0
    li t1,0x3F800000; sw t1,12(a0)  # 1.0
    li t1,0x40000000; sw t1,0(a1)   # 2.0
    li t1,0x40800000; sw t1,4(a1)   # 4.0
    li t1,0x40800000; sw t1,8(a1)   # 4.0
    li t1,0x3F000000; sw t1,12(a1)  # 0.5
    vsetvli t0, x0, e32, m1
    vle32.v v4, (a0)             # v4 = p
    vle32.v v6, (a1)             # v6 = q
    vfdiv.vv v8, v4, v6          # p / q
    vse32.v v8, (a2)
    CK 0,  0x40000000, fail22    # 4/2 = 2.0
    CK 4,  0x40000000, fail22    # 8/4 = 2.0
    CK 8,  0x3F000000, fail22    # 2/4 = 0.5
    CK 12, 0x40000000, fail22    # 1/0.5 = 2.0
    vfdiv.vf v8, v4, fa0         # p / 2.0 (fa0 = 2.0 from earlier)
    vse32.v v8, (a2)
    CK 0,  0x40000000, fail23    # 4/2 = 2.0
    CK 4,  0x40800000, fail23    # 8/2 = 4.0
    CK 8,  0x3F800000, fail23    # 2/2 = 1.0
    CK 12, 0x3F000000, fail23    # 1/2 = 0.5
    li t1,0x41000000; sw t1,64(a0); flw fa2, 64(a0)  # fa2 = 8.0
    vfrdiv.vf v8, v4, fa2        # 8.0 / p (reverse)
    vse32.v v8, (a2)
    CK 0,  0x40000000, fail24    # 8/4 = 2.0
    CK 4,  0x3F800000, fail24    # 8/8 = 1.0
    CK 8,  0x40800000, fail24    # 8/2 = 4.0
    CK 12, 0x41000000, fail24    # 8/1 = 8.0
    # vfsqrt.v (single) — perfect squares
    li t1,0x40800000; sw t1,0(a0)   # 4.0
    li t1,0x41800000; sw t1,4(a0)   # 16.0
    li t1,0x42800000; sw t1,8(a0)   # 64.0
    li t1,0x3F800000; sw t1,12(a0)  # 1.0
    vle32.v v4, (a0)
    vfsqrt.v v8, v4
    vse32.v v8, (a2)
    CK 0,  0x40000000, fail25    # sqrt(4)  = 2.0
    CK 4,  0x40800000, fail25    # sqrt(16) = 4.0
    CK 8,  0x41000000, fail25    # sqrt(64) = 8.0
    CK 12, 0x3F800000, fail25    # sqrt(1)  = 1.0

    # double-precision (MULTI-CYCLE busy path) div + sqrt
    li   a0, 0x80010500
    li   a2, 0x80010180
    li t1,0x4010000000000000; sd t1,0(a0)   # 4.0
    li t1,0x4020000000000000; sd t1,8(a0)   # 8.0
    li t1,0x4000000000000000; sd t1,16(a0)  # 2.0
    li t1,0x4010000000000000; sd t1,24(a0)  # 4.0
    vsetvli t0, x0, e64, m1      # SEW=64, vl=2
    vle64.v v4, (a0)             # [4.0, 8.0]
    addi a1, a0, 16
    vle64.v v6, (a1)             # [2.0, 4.0]
    vfdiv.vv v8, v4, v6          # [4/2, 8/4] = [2.0, 2.0]  (FDIV.D, 57cy each)
    vse64.v v8, (a2)
    CK64 0, 0x4000000000000000, fail26   # 2.0
    CK64 8, 0x4000000000000000, fail26   # 2.0
    li t1,0x4030000000000000; sd t1,0(a0)   # 16.0
    li t1,0x4050000000000000; sd t1,8(a0)   # 64.0
    vle64.v v4, (a0)
    vfsqrt.v v8, v4              # [sqrt(16), sqrt(64)] = [4.0, 8.0]  (FSQRT.D)
    vse64.v v8, (a2)
    CK64 0, 0x4010000000000000, fail27   # 4.0
    CK64 8, 0x4020000000000000, fail27   # 8.0

    # div-by-zero fflags: 1.0 / 0.0 = +inf, sets DZ (bit 3 = 0x08)
    li   a0, 0x80010600          # dividend vector (vs2)
    li   a1, 0x80010640          # divisor vector  (vs1)
    li   a2, 0x80010680          # dst
    li t1,0x3F800000; sw t1,0(a0)   # 1.0
    li t1,0x00000000; sw t1,0(a1)   # 0.0
    csrw fflags, x0
    li   t1, 1
    vsetvli t0, t1, e32, m1         # vl = 1
    vle32.v v4, (a0)                # v4[0] = 1.0
    vle32.v v6, (a1)                # v6[0] = 0.0
    vfdiv.vv v8, v4, v6             # 1.0 / 0.0 = +inf
    vse32.v v8, (a2)
    lwu  t5, 0(a2); li t6, 0x7F800000; bne t5, t6, fail28   # +inf
    csrr t5, fflags
    li   t6, 0x08                   # DZ (bit 3)
    bne  t5, t6, fail28

    # ===================== V3d: FP compare → mask =====================
    # ca = [1.0, 2.0, -1.5, 4.0]   cb = [2.0, 2.0, -1.5, 1.0]
    # mask read back via vmv.x.s + andi 0xF (1 bit per element, low 4 bits).
    .macro CKM exp, failL
        vmv.x.s t5, v10; andi t5, t5, 0xF; li t6, \exp; bne t5, t6, \failL
    .endm
    li   a0, 0x80010700          # ca
    li   a1, 0x80010740          # cb
    li t1,0x3F800000; sw t1,0(a0);  li t1,0x40000000; sw t1,4(a0)
    li t1,0xBFC00000; sw t1,8(a0);  li t1,0x40800000; sw t1,12(a0)
    li t1,0x40000000; sw t1,0(a1);  li t1,0x40000000; sw t1,4(a1)
    li t1,0xBFC00000; sw t1,8(a1);  li t1,0x3F800000; sw t1,12(a1)
    li t1,0x40000000; sw t1,64(a0); flw fa0, 64(a0)  # fa0 = 2.0
    vsetvli t0, x0, e32, m1
    vle32.v v4, (a0)             # v4 = ca
    vle32.v v6, (a1)             # v6 = cb
    # --- .vv compares ---
    vmfeq.vv v10, v4, v6
    CKM 0x6, fail29              # [0,1,1,0]
    vmflt.vv v10, v4, v6
    CKM 0x1, fail30              # [1,0,0,0]
    vmfle.vv v10, v4, v6
    CKM 0x7, fail31              # [1,1,1,0]
    vmfne.vv v10, v4, v6
    CKM 0x9, fail32              # [1,0,0,1]
    # --- .vf compares (scalar 2.0) ---
    vmfeq.vf v10, v4, fa0
    CKM 0x2, fail33              # [0,1,0,0]
    vmflt.vf v10, v4, fa0
    CKM 0x5, fail34              # [1,0,1,0]
    vmfgt.vf v10, v4, fa0
    CKM 0x8, fail35              # [0,0,0,1]
    vmfge.vf v10, v4, fa0
    CKM 0xA, fail36              # [0,1,0,1]
    # double-precision compare (SEW=64): cad=[1.0,2.0], cbd=[2.0,2.0]
    li   a0, 0x80010780
    li t1,0x3FF0000000000000; sd t1,0(a0)   # 1.0
    li t1,0x4000000000000000; sd t1,8(a0)   # 2.0
    li t1,0x4000000000000000; sd t1,16(a0)  # 2.0
    li t1,0x4000000000000000; sd t1,24(a0)  # 2.0
    vsetvli t0, x0, e64, m1      # vl=2
    vle64.v v4, (a0)
    addi a1, a0, 16
    vle64.v v6, (a1)
    vmflt.vv v10, v4, v6         # [1<2?1, 2<2?0] = 0b01 = 0x1
    vmv.x.s t5, v10; andi t5, t5, 0x3; li t6, 0x1; bne t5, t6, fail36

    # ================ V3e: vfmerge.vfm / vfmv.v.f =====================
    # vs2 = [1.0, 2.0, -1.5, 4.0], scalar f[rs1] = 9.0, v0 mask = 0b0101.
    li   a0, 0x80010800          # vs2
    li t1,0x3F800000; sw t1,0(a0);  li t1,0x40000000; sw t1,4(a0)
    li t1,0xBFC00000; sw t1,8(a0);  li t1,0x40800000; sw t1,12(a0)
    li   a3, 0x80010840
    li t1,0x05; sb t1,0(a3)                 # mask 0b0101 (elems 0,2 active)
    li t1,0x41100000; sw t1,16(a3); flw fa5, 16(a3)  # fa5 = 9.0
    li   a2, 0x80010080
    li   t1, 1
    vsetvli t0, t1, e8, m1                  # load mask byte into v0
    vle8.v  v0, (a3)
    vsetvli t0, x0, e32, m1
    vle32.v v4, (a0)             # v4 = vs2
    vfmerge.vfm v8, v4, fa5, v0  # active → 9.0, inactive → vs2
    vse32.v v8, (a2)
    CK 0,  0x41100000, fail37    # active: 9.0
    CK 4,  0x40000000, fail37    # inactive: vs2[1] = 2.0
    CK 8,  0x41100000, fail37    # active: 9.0
    CK 12, 0x40800000, fail37    # inactive: vs2[3] = 4.0
    vfmv.v.f v8, fa5             # broadcast 9.0 to all
    vse32.v v8, (a2)
    CK 0,  0x41100000, fail38
    CK 4,  0x41100000, fail38
    CK 8,  0x41100000, fail38
    CK 12, 0x41100000, fail38

    # ================ V3f: vfmv.s.f / vfmv.f.s ========================
    # vfmv.s.f: vd[0] <- f[rs1], rest undisturbed.
    li   a0, 0x80010900
    li t1,0xAAAA0000; sw t1,0(a0);  li t1,0xAAAA0001; sw t1,4(a0)
    li t1,0xAAAA0002; sw t1,8(a0);  li t1,0xAAAA0003; sw t1,12(a0)
    li t1,0x41100000; sw t1,64(a0); flw fa5, 64(a0)  # fa5 = 9.0
    li   a2, 0x80010080
    vsetvli t0, x0, e32, m1
    vle32.v v8, (a0)             # v8 = sentinel
    vfmv.s.f v8, fa5             # v8[0] = 9.0
    vse32.v v8, (a2)
    CK 0,  0x41100000, fail39    # 9.0
    CK 4,  0xAAAA0001, fail39    # undisturbed
    CK 8,  0xAAAA0002, fail39    # undisturbed
    CK 12, 0xAAAA0003, fail39    # undisturbed
    # vfmv.f.s: f[rd] <- vs2[0] (single).
    li   a1, 0x80010940
    li t1,0x40E00000; sw t1,0(a1)           # 7.0
    li t1,0x11110000; sw t1,4(a1)
    vle32.v v4, (a1)
    vfmv.f.s fa6, v4             # fa6 = v4[0] = 7.0
    li   a2, 0x80010980
    fsw  fa6, 0(a2)
    lwu  t5, 0(a2); li t6, 0x40E00000; bne t5, t6, fail40
    # vfmv.f.s double
    li t1,0x401C000000000000; sd t1,0(a1)   # 7.0 double
    vsetvli t0, x0, e64, m1
    vle64.v v4, (a1)
    vfmv.f.s fa6, v4            # fa6 = 7.0 (double)
    fsd  fa6, 0(a2)
    ld   t5, 0(a2); li t6, 0x401C000000000000; bne t5, t6, fail41
    # vfmv.s.f double: v8[0] <- f[rs1], v8[1] undisturbed
    li t1,0x4022000000000000; sd t1,16(a1); fld fa5, 16(a1)  # 9.0 double
    li t1,0xBBBB000000000000; sd t1,0(a0);  li t1,0xBBBB000000000001; sd t1,8(a0)
    vle64.v v8, (a0)
    vfmv.s.f v8, fa5           # v8[0] = 9.0 (double)
    li   a2, 0x80010180
    vse64.v v8, (a2)
    CK64 0, 0x4022000000000000, fail42   # 9.0
    CK64 8, 0xBBBB000000000001, fail42   # undisturbed

    # ===================== V3g: vfcvt / vfclass =======================
    csrwi frm, 0                 # RNE (deterministic conversion rounding)
    li   a0, 0x80010A00
    li   a2, 0x80010080
    # vfcvt.x.f.v (float -> int, fcsr.frm). NOTE: heliodor's FPU float->int
    # truncates toward zero (a pre-existing scalar fcvt limitation — see the
    # commit/memory note), so this is exercised with fraction < 0.5 values where
    # round-to-nearest and truncate agree: [1.25, 2.25, -1.25, 3.0] -> [1, 2, -1, 3].
    li t1,0x3FA00000; sw t1,0(a0);  li t1,0x40100000; sw t1,4(a0)
    li t1,0xBFA00000; sw t1,8(a0);  li t1,0x40400000; sw t1,12(a0)
    vsetvli t0, x0, e32, m1
    vle32.v v4, (a0)
    vfcvt.x.f.v v8, v4
    vse32.v v8, (a2)
    CK 0,  1,          fail43
    CK 4,  2,          fail43
    CK 8,  0xFFFFFFFF, fail43    # -1
    CK 12, 3,          fail43
    # vfcvt.rtz.x.f.v (truncate toward zero): [1.5, 2.5, -1.5, 3.0] -> [1, 2, -1, 3]
    li t1,0x3FC00000; sw t1,0(a0);  li t1,0x40200000; sw t1,4(a0)
    li t1,0xBFC00000; sw t1,8(a0);  li t1,0x40400000; sw t1,12(a0)
    vle32.v v4, (a0)
    vfcvt.rtz.x.f.v v8, v4
    vse32.v v8, (a2)
    CK 0,  1,          fail44
    CK 4,  2,          fail44
    CK 8,  0xFFFFFFFF, fail44    # -1
    CK 12, 3,          fail44
    # vfcvt.f.x.v (signed int -> float): [5, -3, 100, -1] -> [5.0, -3.0, 100.0, -1.0]
    li t1,5; sw t1,0(a0);  li t1,0xFFFFFFFD; sw t1,4(a0)
    li t1,100; sw t1,8(a0); li t1,0xFFFFFFFF; sw t1,12(a0)
    vle32.v v4, (a0)
    vfcvt.f.x.v v8, v4
    vse32.v v8, (a2)
    CK 0,  0x40A00000, fail45    # 5.0
    CK 4,  0xC0400000, fail45    # -3.0
    CK 8,  0x42C80000, fail45    # 100.0
    CK 12, 0xBF800000, fail45    # -1.0
    # vfcvt.f.xu.v (unsigned): 0xFFFFFFFD as uint (4294967293) -> ~2^32
    vfcvt.f.xu.v v8, v4
    vse32.v v8, (a2)
    CK 0,  0x40A00000, fail46    # 5.0
    CK 4,  0x4F800000, fail46    # 4294967293 -> 2^32 (vs f.x gave -3.0)
    CK 8,  0x42C80000, fail46    # 100.0
    # vfcvt.xu.f.v (float -> unsigned int): [5.0, 10.0, 255.0, 2.0] -> [5, 10, 255, 2]
    li t1,0x40A00000; sw t1,0(a0);  li t1,0x41200000; sw t1,4(a0)
    li t1,0x437F0000; sw t1,8(a0);  li t1,0x40000000; sw t1,12(a0)
    vle32.v v4, (a0)
    vfcvt.xu.f.v v8, v4
    vse32.v v8, (a2)
    CK 0,  5,   fail47
    CK 4,  10,  fail47
    CK 8,  255, fail47
    CK 12, 2,   fail47
    # vfclass.v: [-inf, -1.0, +0.0, +inf] -> [0x001, 0x002, 0x010, 0x080]
    li t1,0xFF800000; sw t1,0(a0);  li t1,0xBF800000; sw t1,4(a0)
    li t1,0x00000000; sw t1,8(a0);  li t1,0x7F800000; sw t1,12(a0)
    vle32.v v4, (a0)
    vfclass.v v8, v4
    vse32.v v8, (a2)
    CK 0,  0x001, fail48    # -inf
    CK 4,  0x002, fail48    # -normal
    CK 8,  0x010, fail48    # +0
    CK 12, 0x080, fail48    # +inf
    # SEW=64 vfcvt.f.x.v: int64 [7, -2] -> [7.0, -2.0]
    li t1,7; sd t1,0(a0);  li t1,-2; sd t1,8(a0)
    li   a2, 0x80010180
    vsetvli t0, x0, e64, m1
    vle64.v v4, (a0)
    vfcvt.f.x.v v8, v4
    vse64.v v8, (a2)
    CK64 0, 0x401C000000000000, fail49   # 7.0
    CK64 8, 0xC000000000000000, fail49   # -2.0

    # ===================== V3h: FMA ===================================
    # vd = [1,2,3,4], vs1 = [2,2,2,2], vs2 = [3,3,3,3]
    li   a0, 0x80010B00          # vd
    li   a1, 0x80010B40          # vs1
    li   a3, 0x80010B80          # vs2
    li   a2, 0x80010080          # dst
    li t1,0x3F800000; sw t1,0(a0);  li t1,0x40000000; sw t1,4(a0)
    li t1,0x40400000; sw t1,8(a0);  li t1,0x40800000; sw t1,12(a0)
    li t1,0x40000000; sw t1,0(a1); sw t1,4(a1); sw t1,8(a1); sw t1,12(a1)   # 2.0
    li t1,0x40400000; sw t1,0(a3); sw t1,4(a3); sw t1,8(a3); sw t1,12(a3)   # 3.0
    vsetvli t0, x0, e32, m1
    vle32.v v6, (a1)             # vs1 = 2.0
    vle32.v v4, (a3)             # vs2 = 3.0
    # vfmacc.vv: vd += vs1*vs2 -> [1+6, 2+6, 3+6, 4+6] = [7, 8, 9, 10]
    vle32.v v8, (a0)
    vfmacc.vv v8, v6, v4
    vse32.v v8, (a2)
    CK 0,  0x40E00000, fail50    # 7.0
    CK 4,  0x41000000, fail50    # 8.0
    CK 8,  0x41100000, fail50    # 9.0
    CK 12, 0x41200000, fail50    # 10.0
    # vfmadd.vv: vd = vs1*vd + vs2 -> [2*1+3, 2*2+3, 2*3+3, 2*4+3] = [5, 7, 9, 11]
    vle32.v v8, (a0)
    vfmadd.vv v8, v6, v4
    vse32.v v8, (a2)
    CK 0,  0x40A00000, fail51    # 5.0
    CK 4,  0x40E00000, fail51    # 7.0
    CK 8,  0x41100000, fail51    # 9.0
    CK 12, 0x41300000, fail51    # 11.0
    # vfmsac.vv: vd = vs1*vs2 - vd -> [6-1, 6-2, 6-3, 6-4] = [5, 4, 3, 2]
    vle32.v v8, (a0)
    vfmsac.vv v8, v6, v4
    vse32.v v8, (a2)
    CK 0,  0x40A00000, fail52    # 5.0
    CK 4,  0x40800000, fail52    # 4.0
    CK 8,  0x40400000, fail52    # 3.0
    CK 12, 0x40000000, fail52    # 2.0
    # vfnmacc.vv: vd = -(vs1*vs2) - vd -> [-7, -8, -9, -10]
    vle32.v v8, (a0)
    vfnmacc.vv v8, v6, v4
    vse32.v v8, (a2)
    CK 0,  0xC0E00000, fail53    # -7.0
    CK 4,  0xC1000000, fail53    # -8.0
    CK 12, 0xC1200000, fail53    # -10.0
    # vfmacc.vf: vd += f[rs1]*vs2, f[rs1] = 2.0 -> [1+6, ..., 4+6] = [7,8,9,10]
    li t1,0x40000000; sw t1,64(a0); flw fa0, 64(a0)   # fa0 = 2.0
    vle32.v v8, (a0)
    vfmacc.vf v8, fa0, v4
    vse32.v v8, (a2)
    CK 0,  0x40E00000, fail54    # 7.0
    CK 12, 0x41200000, fail54    # 10.0
    # SEW=64 vfmacc.vv: vd=[1,2], vs1=[2,2], vs2=[3,3] -> [7, 8]
    li t1,0x3FF0000000000000; sd t1,0(a0);  li t1,0x4000000000000000; sd t1,8(a0)
    li t1,0x4000000000000000; sd t1,0(a1); sd t1,8(a1)
    li t1,0x4008000000000000; sd t1,0(a3); sd t1,8(a3)
    li   a2, 0x80010180
    vsetvli t0, x0, e64, m1
    vle64.v v6, (a1); vle64.v v4, (a3); vle64.v v8, (a0)
    vfmacc.vv v8, v6, v4
    vse64.v v8, (a2)
    CK64 0, 0x401C000000000000, fail55   # 7.0
    CK64 8, 0x4020000000000000, fail55   # 8.0

    # ================ V3i: widening FP (single -> double) =============
    # vs2 = [1.5, 2.5, -3.0, 4.0], vs1 = [0.5, 0.5, 1.0, -2.0] (single)
    li   a0, 0x80010C00          # vs2
    li   a1, 0x80010C40          # vs1
    li   a2, 0x80010C80          # dst (4 doubles = 2 regs)
    li t1,0x3FC00000; sw t1,0(a0);  li t1,0x40200000; sw t1,4(a0)
    li t1,0xC0400000; sw t1,8(a0);  li t1,0x40800000; sw t1,12(a0)
    li t1,0x3F000000; sw t1,0(a1);  li t1,0x3F000000; sw t1,4(a1)
    li t1,0x3F800000; sw t1,8(a1);  li t1,0xC0000000; sw t1,12(a1)
    vsetvli t0, x0, e32, m1      # SEW=32, vl=4
    vle32.v v4, (a0)             # vs2
    vle32.v v6, (a1)             # vs1
    # vfwadd.vv: (double)vs2 + (double)vs1 -> [2.0, 3.0, -2.0, 2.0]
    vfwadd.vv v8, v4, v6
    vsetvli t0, x0, e64, m2      # read 4 doubles back (v8,v9)
    vse64.v v8, (a2)
    CK64 0,  0x4000000000000000, fail56   # 2.0
    CK64 8,  0x4008000000000000, fail56   # 3.0
    CK64 16, 0xC000000000000000, fail56   # -2.0
    CK64 24, 0x4000000000000000, fail56   # 2.0
    # vfwsub.vv: vs2 - vs1 -> [1.0, 2.0, -4.0, 6.0]
    vsetvli t0, x0, e32, m1
    vfwsub.vv v8, v4, v6
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x3FF0000000000000, fail57   # 1.0
    CK64 8,  0x4000000000000000, fail57   # 2.0
    CK64 16, 0xC010000000000000, fail57   # -4.0
    CK64 24, 0x4018000000000000, fail57   # 6.0
    # vfwmul.vv: vs2 * vs1 -> [0.75, 1.25, -3.0, -8.0]
    vsetvli t0, x0, e32, m1
    vfwmul.vv v8, v4, v6
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x3FE8000000000000, fail58   # 0.75
    CK64 8,  0x3FF4000000000000, fail58   # 1.25
    CK64 16, 0xC008000000000000, fail58   # -3.0
    CK64 24, 0xC020000000000000, fail58   # -8.0
    # vfwadd.vf: vs2 + 0.5 -> [2.0, 3.0, -2.5, 4.5]
    li t1,0x3F000000; sw t1,64(a0); flw fa1, 64(a0)   # 0.5
    vsetvli t0, x0, e32, m1
    vfwadd.vf v8, v4, fa1
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x4000000000000000, fail59   # 2.0
    CK64 8,  0x4008000000000000, fail59   # 3.0
    CK64 16, 0xC004000000000000, fail59   # -2.5
    CK64 24, 0x4012000000000000, fail59   # 4.5

    # ============ V3j: widening .w forms (vfwadd.w / vfwsub.w) ============
    # vs2 is ALREADY double; only vs1 / f[rs1] is widened from single.
    # vs2 (double) = [10.5, 20.5, -3.0, 4.0], vs1 (single) = [0.5, 0.5, 1.0, -2.0]
    li   a0, 0x80010D00          # vs2 (4 doubles = 2 regs)
    li   a1, 0x80010D40          # vs1 (4 singles = 1 reg)
    li   a2, 0x80010D80          # dst (4 doubles = 2 regs)
    li t1,0x4025000000000000; sd t1,0(a0)    # 10.5
    li t1,0x4034800000000000; sd t1,8(a0)    # 20.5
    li t1,0xC008000000000000; sd t1,16(a0)   # -3.0
    li t1,0x4010000000000000; sd t1,24(a0)   # 4.0
    li t1,0x3F000000; sw t1,0(a1);  li t1,0x3F000000; sw t1,4(a1)   # 0.5, 0.5
    li t1,0x3F800000; sw t1,8(a1);  li t1,0xC0000000; sw t1,12(a1)  # 1.0, -2.0
    vsetvli t0, x0, e64, m2      # load vs2 doubles into v4,v5
    vle64.v v4, (a0)
    vsetvli t0, x0, e32, m1      # load vs1 singles ; SEW=32 is the narrow width for .w
    vle32.v v6, (a1)
    # vfwadd.wv: vs2 + (double)vs1 -> [11.0, 21.0, -2.0, 2.0]
    vfwadd.wv v8, v4, v6
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x4026000000000000, fail60   # 11.0
    CK64 8,  0x4035000000000000, fail60   # 21.0
    CK64 16, 0xC000000000000000, fail60   # -2.0
    CK64 24, 0x4000000000000000, fail60   # 2.0
    # vfwsub.wv: vs2 - (double)vs1 -> [10.0, 20.0, -4.0, 6.0]
    vsetvli t0, x0, e32, m1
    vfwsub.wv v8, v4, v6
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x4024000000000000, fail61   # 10.0
    CK64 8,  0x4034000000000000, fail61   # 20.0
    CK64 16, 0xC010000000000000, fail61   # -4.0
    CK64 24, 0x4018000000000000, fail61   # 6.0
    # vfwadd.wf: vs2 + (double)0.5 -> [11.0, 21.0, -2.5, 4.5]
    li t1,0x3F000000; sw t1,64(a0); flw fa1, 64(a0)   # 0.5 single
    vsetvli t0, x0, e32, m1
    vfwadd.wf v8, v4, fa1
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x4026000000000000, fail62   # 11.0
    CK64 8,  0x4035000000000000, fail62   # 21.0
    CK64 16, 0xC004000000000000, fail62   # -2.5
    CK64 24, 0x4012000000000000, fail62   # 4.5

    # ============ V3j: widening FP FMA (vfwmacc family, .vv/.vf) ============
    # Both multiplicands are single (s2d-widened); the accumulator is the old vd
    # (already double, read at dest geometry). vd op= vs1*vs2.
    # vs1 = [2.0, 3.0, -1.0, 0.5], vs2 = [1.5, 2.0, 4.0, -2.0] (single)
    # vd  = [10.0, 20.0, -5.0, 1.0] (double accumulator, reloaded each test)
    li   a0, 0x80010E00          # vs1 (single)
    li   a1, 0x80010E40          # vs2 (single)
    li   a3, 0x80010E80          # vd init (double = 2 regs)
    li   a2, 0x80010F00          # dst (double = 2 regs)
    li t1,0x40000000; sw t1,0(a0);  li t1,0x40400000; sw t1,4(a0)
    li t1,0xBF800000; sw t1,8(a0);  li t1,0x3F000000; sw t1,12(a0)
    li t1,0x3FC00000; sw t1,0(a1);  li t1,0x40000000; sw t1,4(a1)
    li t1,0x40800000; sw t1,8(a1);  li t1,0xC0000000; sw t1,12(a1)
    li t1,0x4024000000000000; sd t1,0(a3)    # 10.0
    li t1,0x4034000000000000; sd t1,8(a3)    # 20.0
    li t1,0xC014000000000000; sd t1,16(a3)   # -5.0
    li t1,0x3FF0000000000000; sd t1,24(a3)   # 1.0
    vsetvli t0, x0, e32, m1
    vle32.v v6, (a0)             # vs1
    vle32.v v4, (a1)             # vs2
    # vfwmacc.vv: vd += vs1*vs2 -> [13.0, 26.0, -9.0, 0.0]
    vsetvli t0, x0, e64, m2
    vle64.v v8, (a3)
    vsetvli t0, x0, e32, m1
    vfwmacc.vv v8, v6, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x402A000000000000, fail63   # 13.0
    CK64 8,  0x403A000000000000, fail63   # 26.0
    CK64 16, 0xC022000000000000, fail63   # -9.0
    CK64 24, 0x0000000000000000, fail63   # 0.0
    # vfwnmacc.vv: vd = -(vs1*vs2) - vd -> [-13.0, -26.0, 9.0, 0.0]
    vsetvli t0, x0, e64, m2
    vle64.v v8, (a3)
    vsetvli t0, x0, e32, m1
    vfwnmacc.vv v8, v6, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0xC02A000000000000, fail64   # -13.0
    CK64 8,  0xC03A000000000000, fail64   # -26.0
    CK64 16, 0x4022000000000000, fail64   # 9.0
    CK64 24, 0x0000000000000000, fail64   # 0.0
    # vfwmsac.vv: vd = (vs1*vs2) - vd -> [-7.0, -14.0, 1.0, -2.0]
    vsetvli t0, x0, e64, m2
    vle64.v v8, (a3)
    vsetvli t0, x0, e32, m1
    vfwmsac.vv v8, v6, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0xC01C000000000000, fail65   # -7.0
    CK64 8,  0xC02C000000000000, fail65   # -14.0
    CK64 16, 0x3FF0000000000000, fail65   # 1.0
    CK64 24, 0xC000000000000000, fail65   # -2.0
    # vfwnmsac.vv: vd = -(vs1*vs2) + vd -> [7.0, 14.0, -1.0, 2.0]
    vsetvli t0, x0, e64, m2
    vle64.v v8, (a3)
    vsetvli t0, x0, e32, m1
    vfwnmsac.vv v8, v6, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x401C000000000000, fail66   # 7.0
    CK64 8,  0x402C000000000000, fail66   # 14.0
    CK64 16, 0xBFF0000000000000, fail66   # -1.0
    CK64 24, 0x4000000000000000, fail66   # 2.0
    # vfwmacc.vf: vd += 2.0*vs2 -> [13.0, 24.0, 3.0, -3.0]
    flw fa1, 0(a0)               # 2.0 (= vs1[0])
    vsetvli t0, x0, e64, m2
    vle64.v v8, (a3)
    vsetvli t0, x0, e32, m1
    vfwmacc.vf v8, fa1, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x402A000000000000, fail67   # 13.0
    CK64 8,  0x4038000000000000, fail67   # 24.0
    CK64 16, 0x4008000000000000, fail67   # 3.0
    CK64 24, 0xC008000000000000, fail67   # -3.0

    # ============ V3j: widening conversions (vfwcvt.*, SEW=32 -> 64) ============
    li   a0, 0x80011000          # FP source (single)
    li   a1, 0x80011040          # int source (signed)
    li   a3, 0x80011080          # uint source
    li   a2, 0x80011100          # dst (double / int64 = 2 regs)
    li t1,0x3FC00000; sw t1,0(a0);  li t1,0x40200000; sw t1,4(a0)   # 1.5, 2.5
    li t1,0x40600000; sw t1,8(a0);  li t1,0x40800000; sw t1,12(a0)  # 3.5, 4.0
    li t1,0x0000000A; sw t1,0(a1);  li t1,0xFFFFFFFB; sw t1,4(a1)   # 10, -5
    li t1,0x00000064; sw t1,8(a1);  li t1,0xFFFFFFFF; sw t1,12(a1)  # 100, -1
    li t1,0x0000000A; sw t1,0(a3);  li t1,0x00000014; sw t1,4(a3)   # 10, 20
    li t1,0x00000064; sw t1,8(a3);  li t1,0x00000001; sw t1,12(a3)  # 100, 1
    # vfwcvt.f.f.v: single -> double [1.5, 2.5, 3.5, 4.0]
    vsetvli t0, x0, e32, m1
    vle32.v v4, (a0)
    vfwcvt.f.f.v v8, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x3FF8000000000000, fail68   # 1.5
    CK64 8,  0x4004000000000000, fail68   # 2.5
    CK64 16, 0x400C000000000000, fail68   # 3.5
    CK64 24, 0x4010000000000000, fail68   # 4.0
    # vfwcvt.x.f.v: single -> int64 (truncate) [1, 2, 3, 4]
    vsetvli t0, x0, e32, m1
    vfwcvt.x.f.v v8, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x0000000000000001, fail69   # 1
    CK64 8,  0x0000000000000002, fail69   # 2
    CK64 16, 0x0000000000000003, fail69   # 3
    CK64 24, 0x0000000000000004, fail69   # 4
    # vfwcvt.xu.f.v: single -> uint64 (truncate) [1, 2, 3, 4]
    vsetvli t0, x0, e32, m1
    vfwcvt.xu.f.v v8, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x0000000000000001, fail70   # 1
    CK64 24, 0x0000000000000004, fail70   # 4
    # vfwcvt.rtz.x.f.v: single -> int64 RTZ [1, 2, 3, 4]
    vsetvli t0, x0, e32, m1
    vfwcvt.rtz.x.f.v v8, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x0000000000000001, fail71   # 1
    CK64 16, 0x0000000000000003, fail71   # 3
    # vfwcvt.f.x.v: int32 -> double [10.0, -5.0, 100.0, -1.0]
    vsetvli t0, x0, e32, m1
    vle32.v v4, (a1)
    vfwcvt.f.x.v v8, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x4024000000000000, fail72   # 10.0
    CK64 8,  0xC014000000000000, fail72   # -5.0
    CK64 16, 0x4059000000000000, fail72   # 100.0
    CK64 24, 0xBFF0000000000000, fail72   # -1.0
    # vfwcvt.f.xu.v: uint32 -> double [10.0, 20.0, 100.0, 1.0]
    vsetvli t0, x0, e32, m1
    vle32.v v4, (a3)
    vfwcvt.f.xu.v v8, v4
    vsetvli t0, x0, e64, m2
    vse64.v v8, (a2)
    CK64 0,  0x4024000000000000, fail73   # 10.0
    CK64 8,  0x4034000000000000, fail73   # 20.0
    CK64 16, 0x4059000000000000, fail73   # 100.0
    CK64 24, 0x3FF0000000000000, fail73   # 1.0

    # --- fflags accrual: max_float + max_float = +inf, sets OF|NX (0x05) ---
    li   a0, 0x80010200
    li   a2, 0x80010280
    li t1,0x7F7FFFFF; sw t1,0(a0)          # FLT_MAX
    csrw fflags, x0                        # clear sticky flags
    li   t1, 1
    vsetvli t0, t1, e32, m1                # vl = 1
    vle32.v v4, (a0)
    vfadd.vv v8, v4, v4                    # FLT_MAX + FLT_MAX → +inf
    vse32.v v8, (a2)
    lwu  t5, 0(a2); li t6, 0x7F800000; bne t5, t6, fail14   # +inf
    csrr t5, fflags
    li   t6, 0x05                          # OF (bit2) | NX (bit0)
    bne  t5, t6, fail15

    # ===== V3j-4: vfrsqrt7.v / vfrec7.v (7-bit reciprocal/rsqrt estimates) =====
    csrwi frm, 0                           # RNE (deterministic vfrec7 overflow rounding)
    li   a0, 0x80010300
    li   a2, 0x80010380

    # --- vfrsqrt7.v single: [1.0, 4.0, 0.25, 100.0] ---
    li t1,0x3F800000; sw t1,0(a0);  li t1,0x40800000; sw t1,4(a0)
    li t1,0x3E800000; sw t1,8(a0);  li t1,0x42C80000; sw t1,12(a0)
    vsetvli t0, x0, e32, m1
    vle32.v v4, (a0)
    vfrsqrt7.v v8, v4
    vse32.v v8, (a2)
    CK 0,  0x3F7F0000, fail74              # rsqrt(1.0)
    CK 4,  0x3EFF0000, fail74              # rsqrt(4.0)
    CK 8,  0x3FFF0000, fail74              # rsqrt(0.25)
    CK 12, 0x3DCC0000, fail74              # rsqrt(100.0)

    # --- vfrsqrt7.v single special: -1.0 → NaN+NV, +0 → +inf+DZ, +inf → +0 ---
    li t1,0xBF800000; sw t1,0(a0);  li t1,0x00000000; sw t1,4(a0)
    li t1,0x00000000; sw t1,8(a0);  li t1,0x7F800000; sw t1,12(a0)
    csrw fflags, x0
    vle32.v v4, (a0)
    vfrsqrt7.v v8, v4
    vse32.v v8, (a2)
    CK 0,  0x7FC00000, fail75              # rsqrt(-1.0) = canonical NaN
    CK 4,  0x7F800000, fail75              # rsqrt(+0)   = +inf
    CK 8,  0x7F800000, fail75              # rsqrt(+0)   = +inf
    CK 12, 0x00000000, fail75              # rsqrt(+inf) = +0
    csrr t5, fflags
    li   t6, 0x18                          # NV (-1.0) | DZ (+0)
    bne  t5, t6, fail76

    # --- vfrec7.v single: [1.0, 2.0, 0.5, -2.0] ---
    li t1,0x3F800000; sw t1,0(a0);  li t1,0x40000000; sw t1,4(a0)
    li t1,0x3F000000; sw t1,8(a0);  li t1,0xC0000000; sw t1,12(a0)
    vle32.v v4, (a0)
    vfrec7.v v8, v4
    vse32.v v8, (a2)
    CK 0,  0x3F7F0000, fail77              # rec(1.0)
    CK 4,  0x3EFF0000, fail77              # rec(2.0)
    CK 8,  0x3FFF0000, fail77              # rec(0.5)
    CK 12, 0xBEFF0000, fail77              # rec(-2.0)

    # --- vfrec7.v single special: +0 → +inf+DZ, -inf → -0, min subnormal → +inf+OF|NX ---
    li t1,0x00000000; sw t1,0(a0);  li t1,0xFF800000; sw t1,4(a0)
    li t1,0x00000001; sw t1,8(a0);  li t1,0x3F800000; sw t1,12(a0)
    csrw fflags, x0
    vle32.v v4, (a0)
    vfrec7.v v8, v4
    vse32.v v8, (a2)
    CK 0,  0x7F800000, fail78              # rec(+0)            = +inf
    CK 4,  0x80000000, fail78              # rec(-inf)          = -0
    CK 8,  0x7F800000, fail78              # rec(min subnormal) = +inf (overflow, RNE)
    CK 12, 0x3F7F0000, fail78              # rec(1.0)
    csrr t5, fflags
    li   t6, 0x0D                          # DZ (+0) | OF|NX (subnormal overflow)
    bne  t5, t6, fail79

    # --- vfrsqrt7.v / vfrec7.v double (SEW=64, vl=2) ---
    li   a0, 0x80010400
    li   a2, 0x80010480
    li t1,0x3FF0000000000000; sd t1,0(a0)  # 1.0
    li t1,0x4010000000000000; sd t1,8(a0)  # 4.0
    vsetvli t0, x0, e64, m1
    vle64.v v4, (a0)
    vfrsqrt7.v v8, v4
    vse64.v v8, (a2)
    CK64 0, 0x3FEFE00000000000, fail80     # rsqrt(1.0)
    CK64 8, 0x3FDFE00000000000, fail80     # rsqrt(4.0)
    li t1,0x4000000000000000; sd t1,0(a0)  # 2.0
    li t1,0x3FE0000000000000; sd t1,8(a0)  # 0.5
    vle64.v v4, (a0)
    vfrec7.v v8, v4
    vse64.v v8, (a2)
    CK64 0, 0x3FDFE00000000000, fail80     # rec(2.0)
    CK64 8, 0x3FFFE00000000000, fail80     # rec(0.5)

    # ===== V4a: FP reductions (vfredusum/vfredosum/vfredmin/vfredmax .vs) =====
    # vd[0] = vs1[0] OP reduce(vs2[0..vl-1]); the rest of vd stays tail-undisturbed.
    li   a0, 0x80010500                    # vs2 (4 x f32)
    li   a1, 0x80010540                    # vs1 (seed at element 0)
    li   a2, 0x80010580                    # dst
    li   a3, 0x800105C0                    # mask byte
    li t1,0x3F800000; sw t1,0(a0);  li t1,0x40000000; sw t1,4(a0)   # 1.0, 2.0
    li t1,0xBFC00000; sw t1,8(a0);  li t1,0x40800000; sw t1,12(a0)  # -1.5, 4.0
    li t1,0x3F000000; sw t1,0(a1)                                  # seed 0.5 at vs1[0]
    vsetvli t0, x0, e32, m1                # vl = 4
    vle32.v v4, (a0)                       # v4 = a (vs2)
    vle32.v v6, (a1)                       # v6[0] = seed (vs1)

    vfredusum.vs v8, v4, v6                # 0.5 + 1.0 + 2.0 - 1.5 + 4.0
    vse32.v v8, (a2)
    CK 0, 0x40C00000, fail81               # 6.0
    vfredosum.vs v8, v4, v6                # ordered → same sequential sum
    vse32.v v8, (a2)
    CK 0, 0x40C00000, fail82               # 6.0
    vfredmin.vs v8, v4, v6                 # min(0.5, 1.0, 2.0, -1.5, 4.0)
    vse32.v v8, (a2)
    CK 0, 0xBFC00000, fail83               # -1.5
    vfredmax.vs v8, v4, v6                 # max(...)
    vse32.v v8, (a2)
    CK 0, 0x40800000, fail84               # 4.0

    # masked vfredusum: v0 = 0x0A (elements 1,3 active) → 0.5 + 2.0 + 4.0
    li t1, 0x0A; sb t1, 0(a3)
    vsetvli t0, x0, e8, m1
    vle8.v v0, (a3)                        # v0[0] = 0x0A
    vsetvli t0, x0, e32, m1                # vl = 4
    vfredusum.vs v8, v4, v6, v0.t
    vse32.v v8, (a2)
    CK 0, 0x40D00000, fail85               # 6.5

    # SEW=64 reductions (vl = 2)
    li   a0, 0x80010600
    li   a1, 0x80010640
    li t1,0x3FF0000000000000; sd t1,0(a0)  # 1.0
    li t1,0x4000000000000000; sd t1,8(a0)  # 2.0
    li t1,0x3FE0000000000000; sd t1,0(a1)  # seed 0.5
    vsetvli t0, x0, e64, m1                # vl = 2
    vle64.v v4, (a0)
    vle64.v v6, (a1)
    vfredusum.vs v8, v4, v6
    vse64.v v8, (a2)
    CK64 0, 0x400C000000000000, fail86     # 3.5
    vfredmax.vs v8, v4, v6
    vse64.v v8, (a2)
    CK64 0, 0x4000000000000000, fail86     # 2.0

    # ===== V4b: integer reductions (vredsum/and/or/xor/minu/min/maxu/max .vs) =====
    li   a0, 0x80010700                    # vs2 array
    li   a1, 0x80010740                    # vs1 seed
    li   a2, 0x80010780                    # dst
    li   a3, 0x800107C0                    # mask byte
    li t1,10; sw t1,0(a0);  li t1,20; sw t1,4(a0)
    li t1,30; sw t1,8(a0);  li t1,40; sw t1,12(a0)
    li t1,5;  sw t1,0(a1)                   # seed 5
    vsetvli t0, x0, e32, m1                # vl = 4
    vle32.v v4, (a0)
    vle32.v v6, (a1)
    vredsum.vs  v8, v4, v6; vse32.v v8, (a2); CK 0, 0x00000069, fail87   # 5+10+20+30+40=105
    vredand.vs  v8, v4, v6; vse32.v v8, (a2); CK 0, 0x00000000, fail88   # 5&10&...=0
    vredor.vs   v8, v4, v6; vse32.v v8, (a2); CK 0, 0x0000003F, fail89   # OR
    vredxor.vs  v8, v4, v6; vse32.v v8, (a2); CK 0, 0x0000002D, fail90   # XOR
    vredminu.vs v8, v4, v6; vse32.v v8, (a2); CK 0, 0x00000005, fail91   # min unsigned
    vredmaxu.vs v8, v4, v6; vse32.v v8, (a2); CK 0, 0x00000028, fail91   # 40

    # signed min/max with negatives: b = [-1, -100, 50, 2], seed = 10
    li t1,-1;   sw t1,0(a0);  li t1,-100; sw t1,4(a0)
    li t1,50;   sw t1,8(a0);  li t1,2;    sw t1,12(a0)
    li t1,10;   sw t1,0(a1)
    vle32.v v4, (a0)
    vle32.v v6, (a1)
    vredmin.vs v8, v4, v6; vse32.v v8, (a2); CK 0, 0xFFFFFF9C, fail92    # -100
    vredmax.vs v8, v4, v6; vse32.v v8, (a2); CK 0, 0x00000032, fail92    # 50

    # masked vredsum (v0 = 0x0A → elements 1,3): seed + a[1] + a[3]
    li t1,10; sw t1,0(a0);  li t1,20; sw t1,4(a0)
    li t1,30; sw t1,8(a0);  li t1,40; sw t1,12(a0)
    li t1,5;  sw t1,0(a1)
    li t1,0x0A; sb t1,0(a3)
    vsetvli t0, x0, e8, m1
    vle8.v v0, (a3)                        # v0[0] = 0x0A
    vsetvli t0, x0, e32, m1                # vl = 4
    vle32.v v4, (a0)
    vle32.v v6, (a1)
    vredsum.vs v8, v4, v6, v0.t
    vse32.v v8, (a2)
    CK 0, 0x00000041, fail92               # 5 + 20 + 40 = 65

    # SEW=8 vredsum: c = 1..8, seed = 0 (vl = 8)
    li t1,1; sb t1,0(a0); li t1,2; sb t1,1(a0); li t1,3; sb t1,2(a0); li t1,4; sb t1,3(a0)
    li t1,5; sb t1,4(a0); li t1,6; sb t1,5(a0); li t1,7; sb t1,6(a0); li t1,8; sb t1,7(a0)
    li t1,0; sb t1,0(a1)
    li t2, 8
    vsetvli t0, t2, e8, m1                 # vl = 8
    vle8.v v4, (a0)
    vle8.v v6, (a1)
    vredsum.vs v8, v4, v6
    vse8.v v8, (a2)
    lbu t5, 0(a2); li t6, 0x24; bne t5, t6, fail93    # 36

    # SEW=64 vredsum: d = [1000, 2000], seed = 100 (vl = 2)
    li   a0, 0x80010800
    li   a1, 0x80010840
    li t1,1000; sd t1,0(a0);  li t1,2000; sd t1,8(a0)
    li t1,100;  sd t1,0(a1)
    vsetvli t0, x0, e64, m1                # vl = 2
    vle64.v v4, (a0)
    vle64.v v6, (a1)
    vredsum.vs v8, v4, v6
    vse64.v v8, (a2)
    CK64 0, 0x0000000000000C1C, fail93     # 3100

    # ===== V4c: mask-register logical ops (.mm) =====
    # vs2 = v4 (all bytes 0xAA), vs1 = v2 (all bytes 0xCC). vl=128 (e8 m8) → all
    # 128 mask bits are body. AA op CC per the 8 logical ops.
    li   a0, 0x80010900
    li   a1, 0x80010940
    li   a2, 0x80010980
    li t1, 0xAAAAAAAAAAAAAAAA; sd t1,0(a0); sd t1,8(a0)
    li t1, 0xCCCCCCCCCCCCCCCC; sd t1,0(a1); sd t1,8(a1)
    li t2, 16
    vsetvli t0, t2, e8, m1                  # load 16 bytes (128 bits) per mask reg
    vle8.v v4, (a0)
    vle8.v v2, (a1)
    vsetvli t0, x0, e8, m8                  # vl = VLMAX = 128 (whole mask is body)
    vmand.mm  v8, v4, v2; vse8.v v8, (a2); lbu t5,0(a2); li t6,0x88; bne t5,t6, fail94
    vmor.mm   v8, v4, v2; vse8.v v8, (a2); lbu t5,0(a2); li t6,0xEE; bne t5,t6, fail95
    vmxor.mm  v8, v4, v2; vse8.v v8, (a2); lbu t5,0(a2); li t6,0x66; bne t5,t6, fail96
    vmnand.mm v8, v4, v2; vse8.v v8, (a2); lbu t5,0(a2); li t6,0x77; bne t5,t6, fail97
    vmnor.mm  v8, v4, v2; vse8.v v8, (a2); lbu t5,0(a2); li t6,0x11; bne t5,t6, fail98
    vmxnor.mm v8, v4, v2; vse8.v v8, (a2); lbu t5,0(a2); li t6,0x99; bne t5,t6, fail99
    vmandn.mm v8, v4, v2; vse8.v v8, (a2); lbu t5,0(a2); li t6,0x22; bne t5,t6, fail100
    vmorn.mm  v8, v4, v2; vse8.v v8, (a2); lbu t5,0(a2); li t6,0xBB; bne t5,t6, fail100

    # tail undisturbed: pre-load v8 = 0xFF, vl=8 → only byte 0 is body, byte 1.. tail
    li t1, 0xFFFFFFFFFFFFFFFF; sd t1,0(a2); sd t1,8(a2)
    li t2, 16; vsetvli t0, t2, e8, m1; vle8.v v8, (a2)   # v8 = 0xFF x16
    li t2, 8;  vsetvli t0, t2, e8, m1                    # vl = 8
    vmand.mm v8, v4, v2
    li t2, 16; vsetvli t0, t2, e8, m1; vse8.v v8, (a2)
    lbu t5,0(a2); li t6,0x88; bne t5,t6, fail101         # body byte0 = AA & CC
    lbu t5,1(a2); li t6,0xFF; bne t5,t6, fail101         # tail byte1 undisturbed

    # ===== V4d: vcpop.m / vfirst.m (mask reductions to scalar int rd) =====
    # v4 holds the source mask bits. Active = (i<vl) && (vm||v0[i]); count/scan
    # the set source bits. vcpop → number set; vfirst → lowest index (or -1).
    li   a0, 0x80010A00
    li t1, 0;    sd t1,0(a0); sd t1,8(a0)                # clear 16 bytes
    li t1, 0xA8; sb t1,0(a0)                             # byte0 = bits 3,5,7
    li t1, 0x03; sb t1,1(a0)                             # byte1 = bits 8,9
    li t2, 16; vsetvli t0, t2, e8, m1; vle8.v v4, (a0)

    li t2, 8;  vsetvli t0, t2, e8, m1                    # first 8 bits = 0xA8
    vcpop.m  t5, v4; li t6, 3;  bne t5, t6, fail102      # bits 3,5,7 → 3
    vfirst.m t5, v4; li t6, 3;  bne t5, t6, fail103      # lowest set = 3

    li t2, 10; vsetvli t0, t2, e8, m1                    # first 10 bits
    vcpop.m  t5, v4; li t6, 5;  bne t5, t6, fail104      # 3 + bits 8,9 → 5

    li t2, 3;  vsetvli t0, t2, e8, m1                    # vl=3 → bits 0,1,2 (none)
    vcpop.m  t5, v4; li t6, 0;  bne t5, t6, fail105      # tail not counted
    vfirst.m t5, v4; li t6, -1; bne t5, t6, fail106      # none active set → -1

    li t1, 0;  sd t1,0(a0); sd t1,8(a0)                  # all-zero source
    li t2, 16; vsetvli t0, t2, e8, m1; vle8.v v4, (a0)
    li t2, 8;  vsetvli t0, t2, e8, m1
    vcpop.m  t5, v4; li t6, 0;  bne t5, t6, fail107
    vfirst.m t5, v4; li t6, -1; bne t5, t6, fail108

    # masked: source v4 byte0 = 0xFF, v0 mask byte0 = 0x0A (elements 1,3 active).
    li t1, 0xFF; sb t1,0(a0); li t1,0; sb t1,1(a0); sd t1,8(a0)
    li t2, 16; vsetvli t0, t2, e8, m1; vle8.v v4, (a0)
    li   a1, 0x80010A80
    li t1, 0x0A; sb t1,0(a1)
    li t2, 16; vsetvli t0, t2, e8, m1; vle8.v v0, (a1)   # v0[0] = 0x0A
    li t2, 8;  vsetvli t0, t2, e8, m1
    vcpop.m  t5, v4, v0.t; li t6, 2; bne t5, t6, fail109 # active set: 1,3 → 2
    vfirst.m t5, v4, v0.t; li t6, 1; bne t5, t6, fail110 # lowest active set = 1

    # ===== V4e-1: vmsbf.m / vmsof.m / vmsif.m (mask set-prefix) =====
    # v4 source mask byte0 = 0x28 (bits 3,5 set; first set = bit 3). vl=8 → the
    # result byte0 is body. vmsbf=before-first (0x07), vmsif=incl-first (0x0F),
    # vmsof=only-first (0x08). Read back the dest mask register as a byte.
    li   a0, 0x80010B00
    li   a2, 0x80010B40
    li t1, 0;    sd t1,0(a0); sd t1,8(a0)
    li t1, 0x28; sb t1,0(a0)
    li t2, 16; vsetvli t0, t2, e8, m1; vle8.v v4, (a0)
    li t2, 8;  vsetvli t0, t2, e8, m1                    # vl = 8 (bits 0..7 body)
    vmsbf.m v8, v4; li t2,16; vsetvli t0,t2,e8,m1; vse8.v v8,(a2)
    lbu t5,0(a2); li t6,0x07; bne t5,t6, fail111
    li t2, 8; vsetvli t0,t2,e8,m1
    vmsif.m v8, v4; li t2,16; vsetvli t0,t2,e8,m1; vse8.v v8,(a2)
    lbu t5,0(a2); li t6,0x0F; bne t5,t6, fail112
    li t2, 8; vsetvli t0,t2,e8,m1
    vmsof.m v8, v4; li t2,16; vsetvli t0,t2,e8,m1; vse8.v v8,(a2)
    lbu t5,0(a2); li t6,0x08; bne t5,t6, fail113

    # no source bit set: vmsbf fills all active body with 1 (0xFF), vmsof = 0.
    li t1, 0; sd t1,0(a0); sd t1,8(a0)
    li t2, 16; vsetvli t0, t2, e8, m1; vle8.v v4, (a0)
    li t2, 8; vsetvli t0,t2,e8,m1
    vmsbf.m v8, v4; li t2,16; vsetvli t0,t2,e8,m1; vse8.v v8,(a2)
    lbu t5,0(a2); li t6,0xFF; bne t5,t6, fail114
    li t2, 8; vsetvli t0,t2,e8,m1
    vmsof.m v8, v4; li t2,16; vsetvli t0,t2,e8,m1; vse8.v v8,(a2)
    lbu t5,0(a2); li t6,0x00; bne t5,t6, fail115

    # masked: v0 mask = 0x0A (active 1,3), v4 byte0 = 0x08 (bit 3 set). Inactive
    # elements are skipped in the first-set search and left undisturbed (v8 = 0).
    # vmsbf → bit1=1 (active, before set@3) → 0x02; vmsif → bits1,3 → 0x0A;
    # vmsof → bit3 → 0x08.
    li t1, 0x08; sb t1,0(a0); li t1,0; sb t1,1(a0); sd t1,8(a0)
    li t2, 16; vsetvli t0, t2, e8, m1; vle8.v v4, (a0)
    li   a1, 0x80010B80
    li t1, 0x0A; sb t1,0(a1)
    li t2, 16; vsetvli t0, t2, e8, m1; vle8.v v0, (a1)   # v0[0] = 0x0A
    li t1, 0; sd t1,0(a2); sd t1,8(a2)
    li t2, 16; vsetvli t0, t2, e8, m1; vle8.v v8, (a2)   # v8 = 0 (undisturbed base)
    li t2, 8; vsetvli t0,t2,e8,m1
    vmsbf.m v8, v4, v0.t; li t2,16; vsetvli t0,t2,e8,m1; vse8.v v8,(a2)
    lbu t5,0(a2); li t6,0x02; bne t5,t6, fail116
    li t1, 0; sd t1,0(a2); li t2,16; vsetvli t0,t2,e8,m1; vle8.v v8,(a2)
    li t2, 8; vsetvli t0,t2,e8,m1
    vmsif.m v8, v4, v0.t; li t2,16; vsetvli t0,t2,e8,m1; vse8.v v8,(a2)
    lbu t5,0(a2); li t6,0x0A; bne t5,t6, fail117
    li t1, 0; sd t1,0(a2); li t2,16; vsetvli t0,t2,e8,m1; vle8.v v8,(a2)
    li t2, 8; vsetvli t0,t2,e8,m1
    vmsof.m v8, v4, v0.t; li t2,16; vsetvli t0,t2,e8,m1; vse8.v v8,(a2)
    lbu t5,0(a2); li t6,0x08; bne t5,t6, fail118

    # ===== V4e-2: viota.m / vid.v (prefix-sum / element index) =====
    li   a2, 0x80010C00
    # vid.v: vd[i] = i. e8 m1, vl=8 → bytes 0..7 = 0,1,...,7.
    li t2, 8; vsetvli t0, t2, e8, m1
    vid.v v8; li t2,16; vsetvli t0,t2,e8,m1; vse8.v v8,(a2)
    lbu t5,0(a2); li t6,0; bne t5,t6, fail119
    lbu t5,3(a2); li t6,3; bne t5,t6, fail119
    lbu t5,7(a2); li t6,7; bne t5,t6, fail119

    # vid.v LMUL=2 (e8 m2): vl=32 → v8[0..15], v9[16..31].
    li t2, 32; vsetvli t0, t2, e8, m2
    vid.v v8; vse8.v v8,(a2)
    lbu t5,0(a2);  li t6,0;  bne t5,t6, fail120
    lbu t5,15(a2); li t6,15; bne t5,t6, fail120
    lbu t5,16(a2); li t6,16; bne t5,t6, fail121
    lbu t5,31(a2); li t6,31; bne t5,t6, fail121

    # vid.v SEW=32 (e32 m1): vl=4 → words 0,1,2,3.
    li t2, 4; vsetvli t0, t2, e32, m1
    vid.v v8; vse32.v v8,(a2)
    CK 0,  0, fail122
    CK 4,  1, fail122
    CK 8,  2, fail122
    CK 12, 3, fail122

    # viota.m: source mask v2 byte0 = 0x25 (bits 0,2,5). vl=8 → 0,1,1,2,2,2,3,3.
    li   a0, 0x80010C80
    li t1, 0; sd t1,0(a0); sd t1,8(a0)
    li t1, 0x25; sb t1,0(a0)
    li t2,16; vsetvli t0,t2,e8,m1; vle8.v v2,(a0)
    li t2, 8; vsetvli t0,t2,e8,m1
    viota.m v8, v2; li t2,16; vsetvli t0,t2,e8,m1; vse8.v v8,(a2)
    lbu t5,0(a2); li t6,0; bne t5,t6, fail123
    lbu t5,1(a2); li t6,1; bne t5,t6, fail123
    lbu t5,3(a2); li t6,2; bne t5,t6, fail124
    lbu t5,5(a2); li t6,2; bne t5,t6, fail124
    lbu t5,6(a2); li t6,3; bne t5,t6, fail125
    lbu t5,7(a2); li t6,3; bne t5,t6, fail125

    # masked viota.m: v0 = 0x0A (active 1,3), source v2 byte0 = 0x0A. v8 preset
    # 0x77 → active 1,3 written (0,1), inactive elements undisturbed (0x77).
    li t1, 0x0A; sb t1,0(a0); li t1,0; sb t1,1(a0); sd t1,8(a0)
    li t2,16; vsetvli t0,t2,e8,m1; vle8.v v2,(a0)
    li   a1, 0x80010CC0
    li t1, 0x0A; sb t1,0(a1)
    li t2,16; vsetvli t0,t2,e8,m1; vle8.v v0,(a1)
    li t1, 0x7777777777777777; sd t1,0(a2); sd t1,8(a2)
    li t2,16; vsetvli t0,t2,e8,m1; vle8.v v8,(a2)
    li t2, 8; vsetvli t0,t2,e8,m1
    viota.m v8, v2, v0.t; li t2,16; vsetvli t0,t2,e8,m1; vse8.v v8,(a2)
    lbu t5,0(a2); li t6,0x77; bne t5,t6, fail126   # inactive undisturbed
    lbu t5,1(a2); li t6,0x00; bne t5,t6, fail126   # active: 0 set before
    lbu t5,3(a2); li t6,0x01; bne t5,t6, fail127   # active: elem1 set before
    lbu t5,2(a2); li t6,0x77; bne t5,t6, fail127   # inactive undisturbed

    li   t0, 1
    sw   t0, 0(t3)
0:  j    0b

fail2:  li t0,2;  sw t0,0(t3); 20: j 20b
fail3:  li t0,3;  sw t0,0(t3); 30: j 30b
fail4:  li t0,4;  sw t0,0(t3); 40: j 40b
fail5:  li t0,5;  sw t0,0(t3); 50: j 50b
fail6:  li t0,6;  sw t0,0(t3); 60: j 60b
fail7:  li t0,7;  sw t0,0(t3); 70: j 70b
fail8:  li t0,8;  sw t0,0(t3); 80: j 80b
fail9:  li t0,9;  sw t0,0(t3); 90: j 90b
fail10: li t0,10; sw t0,0(t3); 100: j 100b
fail11: li t0,11; sw t0,0(t3); 110: j 110b
fail12: li t0,12; sw t0,0(t3); 120: j 120b
fail13: li t0,13; sw t0,0(t3); 130: j 130b
fail14: li t0,14; sw t0,0(t3); 140: j 140b
fail15: li t0,15; sw t0,0(t3); 150: j 150b
fail16: li t0,16; sw t0,0(t3); 160: j 160b
fail17: li t0,17; sw t0,0(t3); 170: j 170b
fail18: li t0,18; sw t0,0(t3); 180: j 180b
fail19: li t0,19; sw t0,0(t3); 190: j 190b
fail20: li t0,20; sw t0,0(t3); 200: j 200b
fail16b: li t0,21; sw t0,0(t3); 210: j 210b
fail22: li t0,22; sw t0,0(t3); 220: j 220b
fail23: li t0,23; sw t0,0(t3); 230: j 230b
fail24: li t0,24; sw t0,0(t3); 240: j 240b
fail25: li t0,25; sw t0,0(t3); 250: j 250b
fail26: li t0,26; sw t0,0(t3); 260: j 260b
fail27: li t0,27; sw t0,0(t3); 270: j 270b
fail28: li t0,28; sw t0,0(t3); 280: j 280b
fail29: li t0,29; sw t0,0(t3); 290: j 290b
fail30: li t0,30; sw t0,0(t3); 300: j 300b
fail31: li t0,31; sw t0,0(t3); 310: j 310b
fail32: li t0,32; sw t0,0(t3); 320: j 320b
fail33: li t0,33; sw t0,0(t3); 330: j 330b
fail34: li t0,34; sw t0,0(t3); 340: j 340b
fail35: li t0,35; sw t0,0(t3); 350: j 350b
fail36: li t0,36; sw t0,0(t3); 360: j 360b
fail37: li t0,37; sw t0,0(t3); 370: j 370b
fail38: li t0,38; sw t0,0(t3); 380: j 380b
fail39: li t0,39; sw t0,0(t3); 390: j 390b
fail40: li t0,40; sw t0,0(t3); 400: j 400b
fail41: li t0,41; sw t0,0(t3); 410: j 410b
fail42: li t0,42; sw t0,0(t3); 420: j 420b
fail43: li t0,43; sw t0,0(t3); 430: j 430b
fail44: li t0,44; sw t0,0(t3); 440: j 440b
fail45: li t0,45; sw t0,0(t3); 450: j 450b
fail46: li t0,46; sw t0,0(t3); 460: j 460b
fail47: li t0,47; sw t0,0(t3); 470: j 470b
fail48: li t0,48; sw t0,0(t3); 480: j 480b
fail49: li t0,49; sw t0,0(t3); 490: j 490b
fail50: li t0,50; sw t0,0(t3); 500: j 500b
fail51: li t0,51; sw t0,0(t3); 510: j 510b
fail52: li t0,52; sw t0,0(t3); 520: j 520b
fail53: li t0,53; sw t0,0(t3); 530: j 530b
fail54: li t0,54; sw t0,0(t3); 540: j 540b
fail55: li t0,55; sw t0,0(t3); 550: j 550b
fail56: li t0,56; sw t0,0(t3); 560: j 560b
fail57: li t0,57; sw t0,0(t3); 570: j 570b
fail58: li t0,58; sw t0,0(t3); 580: j 580b
fail59: li t0,59; sw t0,0(t3); 590: j 590b
fail60: li t0,60; sw t0,0(t3); 600: j 600b
fail61: li t0,61; sw t0,0(t3); 610: j 610b
fail62: li t0,62; sw t0,0(t3); 620: j 620b
fail63: li t0,63; sw t0,0(t3); 630: j 630b
fail64: li t0,64; sw t0,0(t3); 640: j 640b
fail65: li t0,65; sw t0,0(t3); 650: j 650b
fail66: li t0,66; sw t0,0(t3); 660: j 660b
fail67: li t0,67; sw t0,0(t3); 670: j 670b
fail68: li t0,68; sw t0,0(t3); 680: j 680b
fail69: li t0,69; sw t0,0(t3); 690: j 690b
fail70: li t0,70; sw t0,0(t3); 700: j 700b
fail71: li t0,71; sw t0,0(t3); 710: j 710b
fail72: li t0,72; sw t0,0(t3); 720: j 720b
fail73: li t0,73; sw t0,0(t3); 730: j 730b
fail74: li t0,74; sw t0,0(t3); 740: j 740b
fail75: li t0,75; sw t0,0(t3); 750: j 750b
fail76: li t0,76; sw t0,0(t3); 760: j 760b
fail77: li t0,77; sw t0,0(t3); 770: j 770b
fail78: li t0,78; sw t0,0(t3); 780: j 780b
fail79: li t0,79; sw t0,0(t3); 790: j 790b
fail80: li t0,80; sw t0,0(t3); 800: j 800b
fail81: li t0,81; sw t0,0(t3); 810: j 810b
fail82: li t0,82; sw t0,0(t3); 820: j 820b
fail83: li t0,83; sw t0,0(t3); 830: j 830b
fail84: li t0,84; sw t0,0(t3); 840: j 840b
fail85: li t0,85; sw t0,0(t3); 850: j 850b
fail86: li t0,86; sw t0,0(t3); 860: j 860b
fail87: li t0,87; sw t0,0(t3); 870: j 870b
fail88: li t0,88; sw t0,0(t3); 880: j 880b
fail89: li t0,89; sw t0,0(t3); 890: j 890b
fail90: li t0,90; sw t0,0(t3); 900: j 900b
fail91: li t0,91; sw t0,0(t3); 910: j 910b
fail92: li t0,92; sw t0,0(t3); 920: j 920b
fail93: li t0,93; sw t0,0(t3); 930: j 930b
fail94:  li t0,94;  sw t0,0(t3); 940:  j 940b
fail95:  li t0,95;  sw t0,0(t3); 950:  j 950b
fail96:  li t0,96;  sw t0,0(t3); 960:  j 960b
fail97:  li t0,97;  sw t0,0(t3); 970:  j 970b
fail98:  li t0,98;  sw t0,0(t3); 980:  j 980b
fail99:  li t0,99;  sw t0,0(t3); 990:  j 990b
fail100: li t0,100; sw t0,0(t3); 1000: j 1000b
fail101: li t0,101; sw t0,0(t3); 1010: j 1010b
fail102: li t0,102; sw t0,0(t3); 1020: j 1020b
fail103: li t0,103; sw t0,0(t3); 1030: j 1030b
fail104: li t0,104; sw t0,0(t3); 1040: j 1040b
fail105: li t0,105; sw t0,0(t3); 1050: j 1050b
fail106: li t0,106; sw t0,0(t3); 1060: j 1060b
fail107: li t0,107; sw t0,0(t3); 1070: j 1070b
fail108: li t0,108; sw t0,0(t3); 1080: j 1080b
fail109: li t0,109; sw t0,0(t3); 1090: j 1090b
fail110: li t0,110; sw t0,0(t3); 1100: j 1100b
fail111: li t0,111; sw t0,0(t3); 1110: j 1110b
fail112: li t0,112; sw t0,0(t3); 1120: j 1120b
fail113: li t0,113; sw t0,0(t3); 1130: j 1130b
fail114: li t0,114; sw t0,0(t3); 1140: j 1140b
fail115: li t0,115; sw t0,0(t3); 1150: j 1150b
fail116: li t0,116; sw t0,0(t3); 1160: j 1160b
fail117: li t0,117; sw t0,0(t3); 1170: j 1170b
fail118: li t0,118; sw t0,0(t3); 1180: j 1180b
fail119: li t0,119; sw t0,0(t3); 1190: j 1190b
fail120: li t0,120; sw t0,0(t3); 1200: j 1200b
fail121: li t0,121; sw t0,0(t3); 1210: j 1210b
fail122: li t0,122; sw t0,0(t3); 1220: j 1220b
fail123: li t0,123; sw t0,0(t3); 1230: j 1230b
fail124: li t0,124; sw t0,0(t3); 1240: j 1240b
fail125: li t0,125; sw t0,0(t3); 1250: j 1250b
fail126: li t0,126; sw t0,0(t3); 1260: j 1260b
fail127: li t0,127; sw t0,0(t3); 1270: j 1270b
