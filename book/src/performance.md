# Performance

This chapter gives cycle counts, not times: they do not depend on the clock
frequency, which is a property of the synthesis flow and the target. All figures
are from the Veryl simulator with the memory model of the test harness (a fixed
latency AXI4 slave), so DRAM latency is whatever that model provides. Real systems
differ, mostly in how long a cache miss takes.

## Benchmarks

Four bare-metal programs run from the test harness to completion. The harness
freezes the cycle count and the retired-instruction count when the program writes
`tohost`; IPC is instructions retired divided by cycles. No interrupts occur.

| Benchmark | Configuration | Cycles | Instructions | IPC |
|---|---|---|---|---|
| Dhrystone | 2-wide | 271,031 | 264,835 | 0.977 |
| Dhrystone | 4-wide | 207,221 | 264,835 | 1.278 |
| CoreMark | 2-wide | 384,011 | 374,358 | 0.975 |
| CoreMark | 4-wide | 316,724 | 374,358 | 1.182 |
| FP matrix multiply (`fpmm`) | 2-wide | 1,048,864 | 1,517,201 | 1.447 |
| FP matrix multiply (`fpmm`) | 4-wide | 866,089 | 1,517,201 | 1.752 |
| Sparse matrix-vector product (`spmv`) | 2-wide | 41,763 | 37,656 | 0.902 |
| Sparse matrix-vector product (`spmv`) | 4-wide | 32,709 | 37,656 | 1.151 |

CoreMark is the upstream EEMBC source, vendored under `test/c/coremark/`, with one
iteration. The frequency-independent figure is iterations times 10^6 divided by
the cycles: CoreMark/MHz is about **2.60** for the 2-wide core and **3.16** for
the 4-wide core. The harness times the whole program, and the one-time setup is not
amortized over a single iteration, so this is a conservative lower bound on the
steady-state score, not an official one. `spmv` has few instructions and misses
the cache on almost every load, so its IPC mostly shows the memory latency.

The instruction counts are exact and equal in both configurations. The cycle counts
are exact too, and they are reproducible: a rerun gives the same numbers.

### Run them

The benchmarks are `#[ignore]` tests, so pass `--ignored`. All eight run in about
four minutes:

```bash
veryl test --ignored --test test_cbench_              # the 2-wide and 4-wide benchmarks
veryl test --ignored --test test_cbench_w2_coremark   # one benchmark
```

Each test prints a line `arch: tohost=00000001 cycles=<n> instret=<n> ...` and
`<core> bench <name>: tohost=00000001 pass=1`. The hex images are committed under
`test/hex/`. To rebuild them, source the cross toolchain and run
`make -C test/c/dhrystone`, `make -C test/c/bench` and `make -C test/c/coremark`.
The first two use the benchmark sources of the riscv-tests clone in
`test/riscv-arch-test/upstream` (see
[Getting started](getting-started.md#rebuild-test-programs)); CoreMark is vendored.
A CoreMark image rebuilt with a different compiler can differ from the committed
one, and then its cycle count differs too.

## Linux boots and litmus

Cycles to the SBI shutdown (`x3 == 0xAA`) of the boots in
[Running Linux](running-linux.md), and of the four-hart litmus run. Counts of the
boots are reproducible to the cycle for a given source tree, but they move by tens
of thousands of cycles whenever the memory system or the firmware changes by a few
cycles: the time in a boot comes from `mtime`, and a different arrival time of one
timer interrupt shifts the kernel's wait loops by whole timer ticks (400,000 cycles
at the default time base).

| Test | Harts | 2-wide | 4-wide |
|---|---|---|---|
| Linux 5.15 | 1 | 14,695,563 | 12,339,450 |
| Linux 5.15 | 2 | 19,446,659 | 16,876,581 |
| Linux 5.15 | 4 | 25,485,977 | 22,692,494 |
| Linux 6.6 | 1 | 21,497,361 | 18,493,860 |
| Linux 6.6 | 2 | 47,434,921 | 61,570,636 |
| Linux 7.1 | 1 | 19,436,507 | 16,881,517 |
| Linux 7.1 | 2 | 31,242,059 | 36,973,532 |
| Linux 7.1 with vector | 1 | 20,946,860 | 17,991,524 |
| Guest Linux under the hypervisor | 1 | 18,792,075 | 16,328,753 |
| RVWMO litmus battery | 4 | 5,122,506 | 5,201,592 |

The 4-wide core is faster on the single-hart boots. On the 6.6 and 7.1 two-hart
boots it takes more cycles than the 2-wide core. A boot is a poor measure of
throughput, because kernel waits tied to `mtime` and the timing of the other hart
move the count; the benchmarks above are the measure.

### Simulation speed

The Veryl simulator with the default `cc` backend runs the 2-wide core at roughly
35,000 cycles per second on one hart and 2,700 on four harts, so the one-hart 5.15
boot takes about 7 minutes and the four-hart boot about three hours. The 4-wide
core is slower, about 1,300 cycles per second at four harts. Speeds depend on the
machine, and a simulator that falls back from the compiled `cc` backend is 10 to
100 times slower; see [Contributing](contributing.md#the-regression-ladder).

## Area

[Synthesis](soc-integration.md#synthesis) has the logic size of the SoC and the
core on a Xilinx UltraScale+ part.
