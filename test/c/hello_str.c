/* Bare-metal C test using string constants (.rodata) for heliodor.
 * Tests LBU from .rodata via dcache (previously broken with JIT ON).
 */
#define UART_THR (*(volatile char *)0x10000000)
static void putc(char c) { UART_THR = c; }
static void puts(const char *s) { while (*s) putc(*s++); }

static long fib(int n) {
    long a = 0, b = 1;
    for (int i = 0; i < n; i++) {
        long t = a + b; a = b; b = t;
    }
    return a;
}

/* Print decimal (simple, no leading zeros) */
static void put_dec(unsigned long v) {
    char buf[20];
    int i = 0;
    if (v == 0) { putc('0'); return; }
    while (v > 0) { buf[i++] = '0' + (v % 10); v /= 10; }
    while (--i >= 0) putc(buf[i]);
}

void main(void) {
    puts("Hello from C!\n");
    puts("fib(10)=");
    put_dec(fib(10));  /* 55 */
    putc('\n');
    puts("fib(20)=");
    put_dec(fib(20));  /* 6765 */
    putc('\n');
}
