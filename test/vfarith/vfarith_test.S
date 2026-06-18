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
