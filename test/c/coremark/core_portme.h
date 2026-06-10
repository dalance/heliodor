/* Heliodor baremetal port of CoreMark.
 * Adapted from EEMBC riscv64-baremetal port (Apache 2.0).
 * Differences:
 *   - HAS_FLOAT=0, HAS_PRINTF=0, HAS_STDIO=0 (sim-only, no console output)
 *   - main returns 0; pass/fail signaled via tohost in start.S
 *   - Time via rdcycle (csrr cycle)
 */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#define HAS_FLOAT  0
#define HAS_TIME_H 0
#define USE_CLOCK  0
#define HAS_STDIO  0
#define HAS_PRINTF 0

#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0

typedef unsigned long int size_t;
typedef unsigned long int clock_t;
typedef clock_t CORE_TICKS;

#ifndef NULL
#define NULL ((void *)0)
#endif

#define COMPILER_VERSION "GCC " __VERSION__
#define COMPILER_FLAGS   "rv64imafdc -O2"
#define MEM_LOCATION     "STATIC"

typedef signed short      ee_s16;
typedef unsigned short    ee_u16;
typedef signed int        ee_s32;
typedef double            ee_f32;
typedef unsigned char     ee_u8;
typedef unsigned int      ee_u32;
typedef unsigned long long ee_ptr_int;
typedef size_t            ee_size_t;

extern ee_u32 default_num_contexts;

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x) - 1) & ~3))

#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD  MEM_STATIC
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0

#define MAIN_RETURN_VAL  0
#define MAIN_RETURN_TYPE int

/* Default iterations is set at compile time (see Makefile XCFLAGS) */
#ifndef ITERATIONS
#define ITERATIONS 1
#endif

/* No parallel execution */
typedef int core_portable;

/* Stub: no platform init / fini work needed */
#define portable_init(a, b, c) ((void)0)
#define portable_fini(a)       ((void)0)

/* Stub: ee_printf becomes no-op */
#define ee_printf(...) ((void)0)

#endif /* CORE_PORTME_H */
