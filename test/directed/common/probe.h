// Shared scaffolding for the self-checking directed probes.
//
// tohost (PA 0x80001000):
//   1                    spec behaviour
//   0xB000 + n           behaviour of the old core's deviation Bn. Bits
//                        [23:16] carry the sub-case: its number when the
//                        probe stops at the first hit, or a mask with bit
//                        s-1 for sub-case s when the probe runs them all
//   0xE000 + x           unexpected outcome, the probe is inconclusive
//
// The M-mode trap handler records mcause/mtval/mepc, counts the trap and
// resumes in M-mode at the address in trap_resume (0 reports 0xE0FF).
// It clobbers t5 and t6 only.

#define TOHOST_PA   0x80001000
#define PT_ROOT     0x80010000
#define PT_L1       0x80011000
#define PT_L0       0x80012000
#define SCRATCH     0x80020000
#define VM_BASE     0x80200000
#define UART_THR    0x10000000
#define UART_WRCNT  0x10000100

#define PTE_V 0x01
#define PTE_R 0x02
#define PTE_W 0x04
#define PTE_X 0x08
#define PTE_U 0x10
#define PTE_A 0x40
#define PTE_D 0x80
#define PTE_LEAF (PTE_V | PTE_R | PTE_W | PTE_X | PTE_A | PTE_D)
#define PTE(pa, fl) ((((pa) >> 12) << 10) | (fl))
#define SATP_SV39 ((8 << 60) | (PT_ROOT >> 12))

#define MSTATUS_MPP   0x1800
#define MSTATUS_MPP_S 0x0800
#define MSTATUS_MPRV  (1 << 17)
#define MSTATUS_FS    0x6000
#define MSTATUS_FS_INIT  0x2000
#define MSTATUS_FS_CLEAN 0x4000
#define MSTATUS_VS    0x0600
#define MSTATUS_VS_INIT  0x0200

#define CODE_BUG(n)        (0xB000 + (n))
#define CODE_BUG_SUB(n, s) (0xB000 + (n) + ((s) << 16))
#define CODE_ODD(x)        (0xE000 + (x))

// Write a constant to tohost and spin.
.macro REPORT code
    li      t6, \code
    la      t5, tohost
    sw      t6, 0(t5)
99: j       99b
.endm

// Write a register to tohost and spin.
.macro REPORT_REG reg
    la      t5, tohost
    sw      \reg, 0(t5)
99: j       99b
.endm

.macro SET_RESUME label
    la      t5, \label
    la      t6, trap_resume
    sd      t5, 0(t6)
.endm

// Print "<ch>=<hex of reg>\n" on the UART; clobbers a0-a2, t3, t4.
.macro PRINT ch, reg
    mv      a0, \reg
    li      a1, \ch
    jal     ra, print_kv
.endm

// Leave M-mode for S-mode (or U-mode) at label.
.macro ENTER_S label
    la      t0, \label
    csrw    mepc, t0
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    li      t0, MSTATUS_MPP_S
    csrs    mstatus, t0
    mret
.endm

.macro ENTER_U label
    la      t0, \label
    csrw    mepc, t0
    li      t0, MSTATUS_MPP
    csrc    mstatus, t0
    mret
.endm

    .section .text.init, "ax"
    .globl _start
_start:
    la      t0, trap_entry
    csrw    mtvec, t0
    csrw    medeleg, zero
    csrw    mideleg, zero
    csrw    mie, zero
    // PMP: one NAPOT entry over the whole space, RWX, so S/U may access.
    li      t0, -1
    csrw    pmpaddr0, t0
    li      t0, 0x1f
    csrw    pmpcfg0, t0
    la      sp, stack_top
    j       main

    .section .text
    .align 2
trap_entry:
    la      t6, trap_rec
    csrr    t5, mcause
    sd      t5, 0(t6)
    csrr    t5, mtval
    sd      t5, 8(t6)
    csrr    t5, mepc
    sd      t5, 16(t6)
    ld      t5, 24(t6)
    addi    t5, t5, 1
    sd      t5, 24(t6)
    ld      t5, 32(t6)
    beqz    t5, trap_unexpected
    csrw    mepc, t5
    li      t5, MSTATUS_MPP
    csrs    mstatus, t5
    mret
trap_unexpected:
    la      t6, trap_rec
    ld      a0, 0(t6)
    li      a1, 'c'
    jal     ra, print_kv
    la      t6, trap_rec
    ld      a0, 16(t6)
    li      a1, 'e'
    jal     ra, print_kv
    REPORT  CODE_ODD(0xff)

// a0 = value, a1 = tag character.
print_kv:
    li      t3, UART_THR
    sb      a1, 0(t3)
    li      a2, '='
    sb      a2, 0(t3)
    li      t4, 60
1:  srl     a2, a0, t4
    andi    a2, a2, 0xf
    addi    a2, a2, '0'
    li      a1, '9'
    ble     a2, a1, 2f
    addi    a2, a2, 'a' - '9' - 1
2:  sb      a2, 0(t3)
    addi    t4, t4, -4
    bgez    t4, 1b
    li      a2, '\n'
    sb      a2, 0(t3)
    ret

// Identity Sv39 map: 0x80000000 as one 2 MiB leaf, 0x80200000-0x803fffff
// as 4 KiB leaves through PT_L0 (patch PT_L0 entries to vary them).
// Writes satp in M-mode and fences. Clobbers t0-t4.
vm_init:
    li      t0, PT_ROOT
    li      t1, PT_ROOT + 0x3000
1:  sd      zero, 0(t0)
    addi    t0, t0, 8
    bltu    t0, t1, 1b
    li      t0, PT_ROOT
    li      t1, PTE(PT_L1, PTE_V)
    sd      t1, 16(t0)
    li      t0, PT_L1
    li      t1, PTE(0x80000000, PTE_LEAF)
    sd      t1, 0(t0)
    li      t1, PTE(PT_L0, PTE_V)
    sd      t1, 8(t0)
    li      t0, PT_L0
    li      t1, PTE(VM_BASE, PTE_LEAF)
    li      t2, 1 << 10
    li      t3, 512
1:  sd      t1, 0(t0)
    add     t1, t1, t2
    addi    t0, t0, 8
    addi    t3, t3, -1
    bnez    t3, 1b
    li      t0, SATP_SV39
    csrw    satp, t0
    sfence.vma
    ret

    .section .data
    .align 6
trap_rec:
trap_cause:  .dword 0
trap_tval:   .dword 0
trap_epc:    .dword 0
trap_cnt:    .dword 0
trap_resume: .dword 0
    .align 4
stack:       .space 512
stack_top:

    .section .tohost, "aw", @progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
