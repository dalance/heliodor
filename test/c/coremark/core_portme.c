/* Heliodor baremetal port of CoreMark.
 * Apache 2.0 (see LICENSE.md).
 */
#include "coremark.h"

/* Seeds for CoreMark. PERFORMANCE_RUN with the canonical seeds (0,0,0x66) */
volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* MEM_STATIC: provide a portable_malloc/free that doesn't actually
 * allocate (CoreMark only uses portable_malloc when MEM_METHOD==MEM_MALLOC).
 */
void *portable_malloc(size_t size) { (void)size; return 0; }
void  portable_free  (void *p)     { (void)p; }

/* Timing — rdcycle (csrr cycle). The MYTIMEDIFF macro computes a 64-bit
 * unsigned cycle count which we expose to CoreMark as CORE_TICKS.
 */
static CORE_TICKS start_time_val;
static CORE_TICKS stop_time_val;

static inline CORE_TICKS read_cycles(void) {
    CORE_TICKS x;
    __asm__ volatile ("rdcycle %0" : "=r"(x));
    return x;
}

void start_time(void) { start_time_val = read_cycles(); }
void stop_time (void) { stop_time_val  = read_cycles(); }

CORE_TICKS get_time(void) {
    return stop_time_val - start_time_val;
}

/* No floating point in this port — return raw ticks. */
secs_ret time_in_secs(CORE_TICKS ticks) {
    /* Pretend each tick is one second so the auto-tune doesn't extend
     * the run beyond ITERATIONS. */
    return (secs_ret)ticks;
}

ee_u32 default_num_contexts = MULTITHREAD;
