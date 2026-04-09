#include <stdint.h>
#include <stddef.h>

/* tohost word: testbench reads this to detect completion */
volatile uint64_t tohost __attribute__((section(".tohost")));

/* Heap bump allocator */
extern char _heap_start[];
static char *heap_ptr = 0;

void *sbrk(ptrdiff_t incr) {
    if (!heap_ptr)
        heap_ptr = _heap_start;
    char *prev = heap_ptr;
    heap_ptr += incr;
    return prev;
}

/* Stubs */
void setStats(int enable) { (void)enable; }

long time(long *t) {
    long cycles;
    __asm__ volatile ("rdcycle %0" : "=r"(cycles));
    if (t) *t = cycles;
    return cycles;
}

int printf(const char *fmt, ...) { (void)fmt; return 0; }

/* Minimal string functions (dhrystone uses strcpy/strcmp) */
char *strcpy(char *dst, const char *src) {
    char *d = dst;
    while ((*d++ = *src++))
        ;
    return dst;
}

int strcmp(const char *s1, const char *s2) {
    while (*s1 && *s1 == *s2) { s1++; s2++; }
    return *(unsigned char *)s1 - *(unsigned char *)s2;
}
