# rvmodel_macros.h
# RVMODEL macro definitions for heliodor on the arch harness (MAP_ARCH:
# DRAM 4 MiB at 0x8000_0000, CLINT 0x0200_0000, PLIC 0x0C00_0000, UART
# 0x1000_0000, every other PA a hole).
# SPDX-License-Identifier: Apache-2.0

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define CLINT_BASE_ADDRESS 0x02000000

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .balign 8; .global tohost; tohost: .dword 0;         \
        .balign 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

// heliodor implements the standard M-mode, so the framework's boot code, trap
// handler and T-SBI run unchanged.
#define STANDARD_SM_SUPPORTED

##### TERMINATION #####

// The harness passes on a retired store of 1 to tohost (0x8000_1000, link.ld)
// and fails on any other non-zero value.
#define RVMODEL_HALT_PASS  \
  li x1, 1                ;\
  la t0, tohost           ;\
  write_tohost_pass:      ;\
    sw x1, 0(t0)          ;\
    sw x0, 4(t0)          ;\
    fence.i               ;\
  self_loop_pass:         ;\
    j self_loop_pass      ;\

#define RVMODEL_HALT_FAIL \
  li x1, 3                ;\
  la t0, tohost           ;\
  write_tohost_fail:      ;\
    sw x1, 0(t0)          ;\
    sw x0, 4(t0)          ;\
    fence.i               ;\
  self_loop_fail:         ;\
    j self_loop_fail      ;\

##### IO #####

// Each byte goes to the UART transmit register.
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR) \
1:                           ;                        \
  lbu  _R1, 0(_STR_PTR)      ;                        \
  beqz _R1, 3f               ;                        \
  li   _R2, 0x10000000       ;                        \
  sw   _R1, 0(_R2)           ;                        \
  addi _STR_PTR, _STR_PTR, 1 ;                        \
  j 1b                       ;                        \
3:

##### Access Fault #####

// A hole in MAP_ARCH: every load, store, AMO, LR/SC, fetch and implicit
// page-table read there raises a precise access fault.
#define RVMODEL_ACCESS_FAULT_ADDRESS 0x50000000

##### Machine Timer #####

#define RVMODEL_MTIMECMP_ADDRESS (CLINT_BASE_ADDRESS + 0x4000)
#define RVMODEL_MTIME_ADDRESS    (CLINT_BASE_ADDRESS + 0xBFF8)

##### Machine Interrupts #####

// Polling iterations while waiting for a requested interrupt to pend.
#define RVMODEL_INTERRUPT_LATENCY 1000

// mtime ticks once every 10 cycles on the harness.
#define RVMODEL_TIMER_INT_SOON_DELAY 100

#define RVMODEL_MSIP_ADDRESS (CLINT_BASE_ADDRESS + 0x0)

// The PLIC sources are harness pins without a software trigger, so machine
// external interrupts are not raised (MEI_INTR_IMPL is false in
// heliodor.yaml). Supervisor software and external interrupts go through
// mip.SSIP and mip.SEIP, so their macros stay undefined.

##### Sscofpmf #####

// Event 5 counts cycles in which a memory port carries a request, so a load
// increments it. The Sail build runs a fence instead, mapped to selector 5 in
// sail.json.
#define RVMODEL_HPM_COUNTER 3
#define RVMODEL_MHPMEVENT_VAL 0x5
#define RVMODEL_MHPMEVENT_CODE(_R1, _R2) \
    lw _R2, 0(_R1)

#endif // _RVMODEL_MACROS_H
