# Phase 12 V6 directed test: fault-only-first vector load (vle<eew>ff.v).
#
# In Bare mode heliodor never raises a data fault (dmem_mmu o_fault =
# vm_enabled && ptw_fault), so to exercise vleff's defining behaviour — trimming
# vl on a fault past element 0 instead of trapping — this test enables Sv39
# paging and runs in S-mode. A 1 GiB gigapage identity-maps DRAM (code, stack,
# tohost, page tables, data buffers); a separate VA window at 0x4000_0000 is
# mapped at 4 KiB granularity with VA 0x4000_1000 left UNMAPPED, so a unit-stride
# load that crosses the 0x4000_1000 boundary faults partway through.
#
#   Subtest 1: vle8ff.v fully inside a mapped page  -> no fault, vl unchanged.
#   Subtest 2: vle8ff.v crossing into the unmapped page at element 8
#              -> vl trims to 8 (no trap); the prefix [0,8) is loaded.
#
# tohost @ 0x80001000: 1 = PASS; >1 = failing check id (99 = unexpected trap).

    .section .text.init
    .globl _start
_start:
    li   t3, 0x80001000           # tohost

    # ---- Seed data in DRAM (M-mode, no paging) ----------------------------
    # data1 @ PA 0x80010000..0x8001000F = 0x10..0x1F (subtest 1, via VA 0x40000000)
    li   t0, 0x80010000
    li   t1, 0x10
    li   t2, 16
1:  sb   t1, 0(t0)
    addi t0, t0, 1
    addi t1, t1, 1
    addi t2, t2, -1
    bnez t2, 1b

    # data2 @ PA 0x80010FF8..0x80010FFF = 0x21..0x28 (subtest 2, via VA 0x40000FF8)
    li   t0, 0x80010FF8
    li   t1, 0x21
    li   t2, 8
2:  sb   t1, 0(t0)
    addi t0, t0, 1
    addi t1, t1, 1
    addi t2, t2, -1
    bnez t2, 2b

    # ---- Zero the page-table region (3 pages @ 0x80002000..0x80004FFF) -----
    li   t0, 0x80002000
    li   t2, 0x80005000
3:  sd   zero, 0(t0)
    addi t0, t0, 8
    blt  t0, t2, 3b

    # ---- Build the Sv39 page tables ---------------------------------------
    # L2 root @ 0x80002000:
    #   [2] VA 0x80000000 -> gigapage PA 0x80000000, RWXAD  (identity-map DRAM)
    li   t0, 0x80002000
    li   t1, 0x200000CF           # (0x80000<<10)|0xCF
    sd   t1, 16(t0)               # entry 2 (VA[38:30]=2)
    #   [1] VA 0x40000000 -> L1 @ 0x80003000 (pointer)
    li   t1, 0x20000C01           # (0x80003<<10)|0x01
    sd   t1, 8(t0)                # entry 1 (VA[38:30]=1)
    # L1 @ 0x80003000:
    #   [0] -> L0 @ 0x80004000 (pointer)
    li   t0, 0x80003000
    li   t1, 0x20001001           # (0x80004<<10)|0x01
    sd   t1, 0(t0)                # entry 0
    # L0 @ 0x80004000:
    #   [0] VA 0x40000000 -> leaf PA 0x80010000, RW AD
    li   t0, 0x80004000
    li   t1, 0x200040C7           # (0x80010<<10)|0xC7
    sd   t1, 0(t0)                # entry 0
    #   [1] VA 0x40001000 -> UNMAPPED (left zero -> page fault)

    # ---- Enable Sv39 + vector, drop to S-mode -----------------------------
    li   t0, 0x8                  # satp.MODE = 8 (Sv39)
    slli t0, t0, 60
    li   t1, 0x80002              # root PPN = 0x80002000 >> 12
    or   t0, t0, t1
    csrw satp, t0
    sfence.vma zero, zero

    # mstatus: MPP=01 (return to S-mode), VS=01 (Initial, enable the vector unit)
    li   t0, (1 << 11) | (1 << 9)
    csrw mstatus, t0

    la   t0, s_entry
    csrw mepc, t0
    mret

# ============================================================
# S-mode test (runs identity-mapped at its link address)
# ============================================================
    .balign 4
s_entry:
    la   t0, s_trap
    csrw stvec, t0
    li   t3, 0x80001000           # tohost (identity-mapped)

    # ---- Subtest 1: no-fault vle8ff (vl must be left unchanged) ------------
    li   t0, 16
    vsetvli t1, t0, e8, m1        # vl = min(16, VLMAX=16) = 16
    li   t2, 16
    bne  t1, t2, fail2
    li   a0, 0x40000000           # base fully inside the mapped page
    vle8ff.v v1, (a0)             # no element faults -> vl unchanged
    csrr t0, vl
    bne  t0, t2, fail3            # vl must still be 16

    li   a1, 0x80011000           # scratch (identity)
    vse8.v v1, (a1)
    lbu  t0, 0(a1)
    li   t1, 0x10
    bne  t0, t1, fail4
    lbu  t0, 15(a1)
    li   t1, 0x1F
    bne  t0, t1, fail5

    # ---- Subtest 2: faulting vle8ff (vl trims to 8) -----------------------
    # Pre-fill scratch with 0xFF so the trimmed store's element count shows.
    li   a1, 0x80011000
    li   t0, 0xFF
    li   t2, 16
4:  sb   t0, 0(a1)
    addi a1, a1, 1
    addi t2, t2, -1
    bnez t2, 4b

    li   t0, 16
    vsetvli t1, t0, e8, m1        # vl = 16 again
    li   a0, 0x40000FF8           # elems 0..7 mapped; elem 8 @ 0x40001000 faults
    vle8ff.v v2, (a0)             # element 8 faults -> trim vl to 8 (NO trap)
    csrr t0, vl
    li   t1, 8
    bne  t0, t1, fail6            # vl must be trimmed to 8

    li   a1, 0x80011000
    vse8.v v2, (a1)               # vl=8 -> stores bytes [0,8); [8,16) stay 0xFF
    lbu  t0, 0(a1)
    li   t1, 0x21
    bne  t0, t1, fail7
    lbu  t0, 7(a1)
    li   t1, 0x28
    bne  t0, t1, fail8
    lbu  t0, 8(a1)
    li   t1, 0xFF                 # element 8 was NOT stored (vl=8) -> sentinel intact
    bne  t0, t1, fail9

    # All checks passed.
    li   t0, 1
    sw   t0, 0(t3)
    j    done

fail2:  li t0, 2;  j fail_w
fail3:  li t0, 3;  j fail_w
fail4:  li t0, 4;  j fail_w
fail5:  li t0, 5;  j fail_w
fail6:  li t0, 6;  j fail_w
fail7:  li t0, 7;  j fail_w
fail8:  li t0, 8;  j fail_w
fail9:  li t0, 9;  j fail_w
fail_w:
    sw   t0, 0(t3)
    j    done

    # Any unexpected trap (e.g. vle8ff wrongly trapping instead of trimming)
    # lands here and reports 99.
    .balign 4
s_trap:
    li   t3, 0x80001000
    li   t0, 99
    sw   t0, 0(t3)
    j    done

done:
    j    done
