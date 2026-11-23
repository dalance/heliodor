# Configuration

The core is generic over one configuration package. The package supplies the
five width axes and every structure size, and nothing else in the design carries
a size. Two packages are supported and tested: `cfg_w2` and `cfg_w4`.

## Where the configuration lives

| Item | File |
|---|---|
| The contract every configuration implements (`proto package core_cfg`) | `src/core/common/core_cfg.veryl` |
| The 2-wide configuration | `src/core/common/cfg_w2.veryl` |
| The 4-wide configuration | `src/core/common/cfg_w4.veryl` |
| Derived constants and the constraint check | `src/core/common/core_types.veryl` |
| Non-generic core wrappers | `src/core/heliodor_core_w.veryl` |

The generic core is `heliodor_core::<CFG: core_cfg>`. `heliodor_core_w2` and
`heliodor_core_w4` instantiate it with `cfg_w2` and `cfg_w4`, so that the SoC and
SystemVerilog wrappers can name one module per configuration. The SoC selects the
core with its `CORE` parameter (`soc_pkg::CoreSel::W2` or `soc_pkg::CoreSel::W4`).
See [SoC integration](soc-integration.md).

## The five axes

The name of a configuration lists the axes in this order: fetch, rename, issue,
memory and commit width.

| Axis | Constant | Meaning | `cfg_w2` | `cfg_w4` |
|---|---|---|---|---|
| Fetch/decode | `FETCH_W` | Operations `extract` delivers per cycle; the number of decode lanes | 2 | 4 |
| Rename/dispatch | `RENAME_W` | Operations renamed and dispatched per cycle | 2 | 4 |
| Issue | `ISSUE_W` | Non-memory issue ports. Memory pipes are not counted here. | 2 | 6 |
| Memory | `MEM_W` | Memory pipes, which equals the number of D-cache CPU ports, DTLB lookup ports and load write-back ports | 1 | 2 |
| Commit | `COMMIT_W` | Operations retired per cycle; the number of retire-record lanes | 2 | 4 |

`FETCH_BYTES` is the fetch block size and must equal `8 * FETCH_W` (16 or 32).

## Structure sizes

Each constant is read only by the module that owns it (and by `core_types`).

| Constant | Owner | `cfg_w2` | `cfg_w4` | Meaning |
|---|---|---|---|---|
| `ROB_N` | `rob` | 64 | 128 | Reorder-buffer entries |
| `LQ_N` | `lq` | 32 | 64 | Load-queue entries |
| `SQ_N` | `sq` | 16 | 32 | Store-queue entries (stores before commit) |
| `SB_N` | `sb` | 8 | 16 | Committed-store buffer, in 64-byte lines |
| `FTQ_N` | `ftq` | 32 | 32 | Fetch-target-queue entries |
| `PRF_INT_N` | `prf` | 96 | 160 | Integer physical registers |
| `PRF_FP_N` | `prf` | 64 | 96 | Floating-point physical registers |
| `NUM_CKPT` | `rename` | 4 | 8 | Rename checkpoints; 0 recovers by walking only |
| `FBQ_N` | `ifu` | 4 | 4 | Fetch buffer, in blocks |
| `DQ_N` | `extract` | 8 | 16 | Decode queue, in operations |
| `RQ_N` | `rename` | 4 | 8 | Rename input queue, in operations |
| `DTLB_N`, `ITLB_N` | `tlb` | 32, 16 | 32, 16 | TLB entries |
| `PTW_D_QN`, `PTW_I_QN` | `ptw` | 4, 1 | 4, 1 | Page-walk request queue depths |
| `REISSUE_W` | `lq` | 1 | 1 | Load-queue re-issues per cycle |
| `DC_NB` | `dcache` | 2 | 4 | Data banks of the D-cache |
| `MSHR_N` | `dcache` | 2 | 2 | D-cache miss-status entries |
| `TRIG_N` | `trig_unit` | 2 | 4 | Sdtrig triggers |
| `PRED_META_W`, `PRED_CKPT_W` | `bpu` | 17, 68 | 27, 69 | Widths of the opaque predictor metadata and checkpoint; `bpu` checks its layout against them |

The L1 cache sizes (32 KiB instruction, 16 KiB data) and the L2 size (128 KiB)
are fixed by the cache modules, not by the configuration package.

The physical address width is not part of the core configuration either. It is
the constant `PALEN` of `pma_pkg` (40 bits) and applies to every configuration;
see [Synthesis](soc-integration.md#synthesis).

## Execution ports and issue queues

`PORT_FU[p]` is the set of functional units on issue port `p`, and `PORT_IQ[p]`
is the issue queue that feeds it. `N_IQ` is the number of queues, `MEM_IQ` the
queue that feeds the memory pipes, and `IQ_N[q]` and `IQ_NSRC[q]` the entry
count and the number of source operands of queue `q`.

`cfg_w2`:

| Port | Units | Queue |
|---|---|---|
| 0 | ALU, BRU, SYS, MUL, DIV | 0 |
| 1 | ALU, FMISC, FMA, FDIV | 0 |
| memory pipe | | 1 |

Queue 0 has 24 entries and 3 sources (the floating-point multiply-add needs
three); queue 1 has 16 entries and 2 sources.

`cfg_w4`:

| Port | Units | Queue |
|---|---|---|
| 0, 1 | ALU, BRU | 0 |
| 2 | ALU, MUL | 0 |
| 3 | ALU, SYS, DIV | 0 |
| 4 | FMA, FMISC | 1 |
| 5 | FMA, FDIV | 1 |
| memory pipes | | 2 |

Queue 0 has 32 entries and 2 sources, queue 1 has 24 entries and 3 sources, and
queue 2 has 24 entries and 2 sources.

## Derived values

`core_types::<CFG>` computes the values that follow from the configuration.
A few that matter when reading the source:

| Value | Formula | `cfg_w2` | `cfg_w4` |
|---|---|---|---|
| `WB_N` (write-back ports) | `ISSUE_W + MEM_W` | 3 | 8 |
| `BRU_N` (branches resolved per cycle) | ports carrying BRU | 1 | 2 |
| `ST_RET_N` (stores retired per cycle) | `MEM_W` | 1 | 2 |
| `WALK_W` (rename walk width) | `RENAME_W` | 2 | 4 |
| `PREG_W` (physical register index width) | index width of the larger register file | 7 | 8 |

## Constraints

The sizes must satisfy structural constraints, for example `FETCH_W` is 1, 2 or
4, `DC_NB` is 2, 4 or 8, every functional-unit kind appears on at least one port,
exactly one port carries `SYS`, and every issue queue is at least `RENAME_W`
entries deep. `core_types::<CFG>::CFG_ERR` has one bit per constraint and is 0
for a legal configuration.

The Veryl language cannot reject a configuration at elaboration time (an
instance of an undefined module is an error whatever the generate condition), so
the check is a test: `test_cfg_constraints` asserts `CFG_ERR == 0` for each
supported configuration, and asserts that two deliberately broken
configurations (`tb/cfg_bad.veryl`) set the expected bits. When you add a
configuration, add it to that test.

## Writing your own configuration

A configuration that satisfies the constraints elaborates and runs, but only
`cfg_w2` and `cfg_w4` are part of the supported and tested set. To try a variant:

1. Create a package that implements `core_cfg`. `tb/cfg_w4_sb8.veryl` is a
   small example that copies every value of `cfg_w4` and changes only `SB_N`.
2. Instantiate `heliodor_core::<your_cfg>` directly for a core-level test, as
   the unit tests in `tb/` do.
3. To use it in the SoC, add a value to `soc_pkg::CoreSel`, a non-generic wrapper
   next to `heliodor_core_w2` in `src/core/heliodor_core_w.veryl`, and a branch
   for it in `heliodor_soc_smp`.

Keep experimental configurations in `tb/` (or on a branch), not in `src/`.

## Limits that do not come from the configuration

These are fixed by the structure of the design:

- The number of harts is 1, 2, 4 or 8.
- `FETCH_W` is at most 4 (a fetch block is at most 32 bytes).
- Only one fetch block is predicted, fetched and extracted per cycle.
- There is one store-drain port; raising `MEM_W` or `SB_N` does not raise the
  drain bandwidth.
- Memory pipe 0 serves the page-table walkers, atomics, non-cacheable accesses
  and the vector unit; raising `MEM_W` does not add bandwidth for them.
- There is one D-cache fill per hart toward `mem_ctrl`, whatever `MSHR_N` is.
- At most one vector operation is renamed per cycle.
- At most one kill and one commit-alone operation (an operation that must
  retire by itself, such as a CSR access) per cycle.
- `TRIG_N` is at most 4.
