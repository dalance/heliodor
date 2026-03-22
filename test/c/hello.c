/* Bare-metal C test for heliodor RV64 processor. */
#define UART_THR (*(volatile char *)0x10000000)
static void putc(char c) { UART_THR = c; }

static long fib(int n) {
    long a = 0, b = 1;
    for (int i = 0; i < n; i++) {
        long t = a + b; a = b; b = t;
    }
    return a;
}

/* Print hex nibble */
static void put_hex4(unsigned v) { putc(v < 10 ? '0' + v : 'a' + v - 10); }
static void put_hex(unsigned long v) {
    for (int i = 60; i >= 0; i -= 4)
        put_hex4((v >> i) & 0xF);
}

void main(void) {
    putc('H'); putc('i'); putc('!'); putc('\n');

    /* fib(10) = 55 = 0x37 */
    long r = fib(10);
    putc('=');
    put_hex(r);
    putc('\n');
}
