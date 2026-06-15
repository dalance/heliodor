# P10 hint bundle: Zihintpause + Zihintntl + Zicbop + Zimop + Zcmop.
#
# All are NOP-class hints EXCEPT mop.r.N / mop.rr.N, which (with no extension
# claiming them) write 0 to rd while reading no source. heliodor already lowers
# ntl.* (add x0,x0,xN), c.ntl.* (c.add x0,xN) and prefetch.{i,r,w}
# (ori x0,rs1,imm) to no-ops; this test pins that they neither trap nor corrupt
# state, and that PAUSE / MOP / C.MOP behave per spec.
#
# zimop/zcmop are not assemblable by the current GCC, so MOP/C.MOP are emitted
# via raw .word / .2byte (encodings from riscv-opcodes).
#
# M-mode, tohost @ 0x80001000.  1 = PASS, 5 = FAIL.

    .section .text.init
    .globl _start
_start:
    li   s0, 0x1111111111111111      # sentinels the hints must not corrupt
    li   s1, 0x2222222222222222

    # ---- Zihintpause ----
    pause                            # must not hang or trap

    # ---- Zihintntl (uncompressed + compressed) ----
    ntl.p1
    ntl.pall
    ntl.s1
    ntl.all
    c.ntl.p1
    c.ntl.all

    # ---- Zicbop prefetch (valid mapped address) ----
    la   t0, _start
    prefetch.i 0(t0)
    prefetch.r 0(t0)
    prefetch.w 0(t0)

    li   t1, 0x1111111111111111      # sentinels intact after the NOP-class hints
    bne  s0, t1, fail
    li   t1, 0x2222222222222222
    bne  s1, t1, fail

    # ---- Zimop mop.r.N: rd <- 0, rs1 untouched ----
    li   a1, 0xDEADBEEF
    li   a2, 0x12345678
    .word 0x81C645F3                 # mop.r.0  a1, a2
    bnez a1, fail
    li   t1, 0x12345678
    bne  a2, t1, fail

    li   a3, 0xCAFEF00D
    li   a4, 0x0BADCABE
    .word 0xCDF746F3                 # mop.r.31 a3, a4
    bnez a3, fail
    li   t1, 0x0BADCABE
    bne  a4, t1, fail

    # ---- Zimop mop.rr.N: rd <- 0, rs1/rs2 untouched ----
    li   a1, 0x55555555
    li   a2, 0x66666666
    li   a3, 0x77777777
    .word 0x82D645F3                 # mop.rr.0 a1, a2, a3
    bnez a1, fail
    li   t1, 0x66666666
    bne  a2, t1, fail
    li   t1, 0x77777777
    bne  a3, t1, fail

    li   a5, 0x0A0A0A0A
    li   a6, 0x0B0B0B0B
    li   a7, 0x0C0C0C0C
    .word 0xCF1847F3                 # mop.rr.7 a5, a6, a7
    bnez a5, fail
    li   t1, 0x0B0B0B0B
    bne  a6, t1, fail
    li   t1, 0x0C0C0C0C
    bne  a7, t1, fail

    # ---- mop.r with rd=x0 is a pure NOP (writes nothing) ----
    li   a2, 0x12345678
    .word 0x81C64073                 # mop.r.0 x0, a2  (rd=x0)
    li   t1, 0x12345678
    bne  a2, t1, fail

    # ---- Zcmop c.mop.N: does nothing (no register write) ----
    li   s0, 0x1234567890ABCDEF
    .2byte 0x6081                    # c.mop.1
    .2byte 0x6781                    # c.mop.15
    li   t1, 0x1234567890ABCDEF
    bne  s0, t1, fail

    # pass
    li   t0, 1
    li   t1, 0x80001000
    sw   t0, 0(t1)
done:
    j    done
fail:
    li   t0, 5
    li   t1, 0x80001000
    sw   t0, 0(t1)
fail_done:
    j    fail_done

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
