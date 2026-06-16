# Phase 11-H5.2b: HS-mode hypervisor startup + trap vector (entered by the
# firmware at 0x80000000 in S-mode, a0=hartid, a1=dtb).

.equ HV_TRAP_SP, 0x80018000          # top of the hypervisor trap stack
.equ FRAME,      256                 # 32 * 8 GPR save frame

    .section .text.init, "ax"
    .globl _start
_start:
    la   sp, _stack_top
.option push
.option norelax
    la   gp, __global_pointer$
.option pop
    # zero BSS
    la   t0, _bss_start
    la   t1, _bss_end
1:  bge  t0, t1, 2f
    sd   zero, 0(t0)
    addi t0, t0, 8
    j    1b
2:
    la   t0, hv_trap_vector
    csrw stvec, t0
    li   t0, HV_TRAP_SP
    csrw sscratch, t0                # trap-stack top for the guest-context swap
    call hv_main                     # (hartid, dtb) — sets up + enters guest
3:  j    3b                          # hv_main does not return on success

# void enter_guest(uint64 sepc, uint64 g_a0, uint64 g_a1) — never returns.
# Enters the guest in VS-mode at sepc with a0=g_a0, a1=g_a1.
    .globl enter_guest
enter_guest:
    csrw sepc, a0
    li   t0, (1 << 7)
    csrs 0x600, t0                   # hstatus.SPV = 1 (SRET -> V=1)
    li   t0, (1 << 8)
    csrs sstatus, t0                 # sstatus.SPP = 1 (S-level -> VS)
    mv   a0, a1                      # guest a0 = hartid
    mv   a1, a2                      # guest a1 = dtb
    sret

# HS trap vector: full guest GPR save/restore around a C handler hv_trap(frame).
    .balign 4
hv_trap_vector:
    csrrw sp, sscratch, sp           # sp = HV_TRAP_SP, sscratch = guest sp
    addi sp, sp, -FRAME
    sd   x1,  1*8(sp)
    sd   x3,  3*8(sp)
    sd   x4,  4*8(sp)
    sd   x5,  5*8(sp)
    sd   x6,  6*8(sp)
    sd   x7,  7*8(sp)
    sd   x8,  8*8(sp)
    sd   x9,  9*8(sp)
    sd   x10, 10*8(sp)
    sd   x11, 11*8(sp)
    sd   x12, 12*8(sp)
    sd   x13, 13*8(sp)
    sd   x14, 14*8(sp)
    sd   x15, 15*8(sp)
    sd   x16, 16*8(sp)
    sd   x17, 17*8(sp)
    sd   x18, 18*8(sp)
    sd   x19, 19*8(sp)
    sd   x20, 20*8(sp)
    sd   x21, 21*8(sp)
    sd   x22, 22*8(sp)
    sd   x23, 23*8(sp)
    sd   x24, 24*8(sp)
    sd   x25, 25*8(sp)
    sd   x26, 26*8(sp)
    sd   x27, 27*8(sp)
    sd   x28, 28*8(sp)
    sd   x29, 29*8(sp)
    sd   x30, 30*8(sp)
    sd   x31, 31*8(sp)
    csrr t0, sscratch                # guest sp
    sd   t0,  2*8(sp)
    addi t0, sp, FRAME               # = HV_TRAP_SP
    csrw sscratch, t0                # restore the trap-stack top for the next trap
    mv   a0, sp                      # frame pointer
    call hv_trap                     # may advance sepc, modify the frame's a0/a1
    ld   x1,  1*8(sp)
    ld   x3,  3*8(sp)
    ld   x4,  4*8(sp)
    ld   x5,  5*8(sp)
    ld   x6,  6*8(sp)
    ld   x7,  7*8(sp)
    ld   x8,  8*8(sp)
    ld   x9,  9*8(sp)
    ld   x10, 10*8(sp)
    ld   x11, 11*8(sp)
    ld   x12, 12*8(sp)
    ld   x13, 13*8(sp)
    ld   x14, 14*8(sp)
    ld   x15, 15*8(sp)
    ld   x16, 16*8(sp)
    ld   x17, 17*8(sp)
    ld   x18, 18*8(sp)
    ld   x19, 19*8(sp)
    ld   x20, 20*8(sp)
    ld   x21, 21*8(sp)
    ld   x22, 22*8(sp)
    ld   x23, 23*8(sp)
    ld   x24, 24*8(sp)
    ld   x25, 25*8(sp)
    ld   x26, 26*8(sp)
    ld   x27, 27*8(sp)
    ld   x28, 28*8(sp)
    ld   x29, 29*8(sp)
    ld   x30, 30*8(sp)
    ld   x31, 31*8(sp)
    ld   x2,  2*8(sp)                # guest sp (restores sp last)
    sret
