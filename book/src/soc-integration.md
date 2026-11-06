# SoC integration

`heliodor_soc_smp` (in `src/core/heliodor_soc_smp.veryl`) is the system you
integrate: 1, 2, 4 or 8 cores, the L2 cache and coherence directory, the memory
controller, the CLINT, the PLIC, a UART, and a Debug Module. Its outside
interface is one AXI4 master port for memory, interrupt inputs, an APB slave port
for the debugger, and observation outputs.

```text
                +--------------------------------------------------+
                |  heliodor_soc_smp                                |
 AXI4 master <--+-- mem_ctrl <-- l2cache <-- [ core h: L1I, L1D ]xN |
 (DRAM, ROM)    |      ^                                           |
                |      +-- memory_bus -- CLINT, PLIC, UART, dm_mem |
 APB slave   -->+-- dmi_apb -- dm -- dm_sba                        |
 (debug)        |                                                  |
 i_ext_irq_src->+-- PLIC                          o_retire, o_chk.. |
                +--------------------------------------------------+
```

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `N_HARTS` | 2 | Number of harts: 1, 2, 4 or 8 |
| `CORE` | `soc_pkg::CoreSel::W2` | Core configuration: `W2` or `W4` (see [Configuration](configuration.md)) |
| `RESET_PC` | `64'h8000_0000` | First fetch address of every hart after reset |
| `PMA_N`, `PMA_REGIONS` | one empty region | Physical memory attribute table (see [Memory map and PMA](#memory-map-and-pma)) |
| `MTIME_SRC`, `MTIME_DIV` | `soc_pkg::MTIME_CYCLE`, 10 | Source and divider of `mtime` (see [Time and interrupts](#time-and-interrupts)) |
| `AXI_WB_N` | `2 * N_HARTS` | Write-buffer entries of the AXI4 master |
| `DM_BASE` | `56'h4000` | Base address of debug memory (see [Debug](#debug)) |
| `UART_WRCNT` | 0 | Test aid: a read of `UART + 0x100` returns the number of UART writes |

`AXI_ID_W`, the width of the AXI ID, is a constant of the module:
`$clog2(N_HARTS * 2 + 1)`. It cannot be overridden.

The power-on default of `PMA_REGIONS` is a single all-zero region. You must pass a
real table.

## Ports

### Clock and reset

`clk` is a rising-edge clock. `rst` is an asynchronous, active-low reset. The
project is built with `clock_type = "posedge"` and `reset_type = "async_low"`.

### AXI4 master port

The port is flat, with the usual names: `o_axi_ar*`/`i_axi_ar*`, `o_axi_aw*`,
`o_axi_w*`, `i_axi_r*`, `i_axi_b*` (for example `o_axi_arvalid`,
`i_axi_arready`, `o_axi_araddr`, `i_axi_rdata`).

| Item | Value |
|---|---|
| Data width | 64 bits |
| Address width | 56 bits (the physical address, unmodified) |
| ID width | `AXI_ID_W` |
| `AxSIZE`, `AxBURST` | 3 (8 bytes), INCR |
| `AxLOCK`, `AxPROT`, `AxQOS` | 0 |
| `AxCACHE` | `4'b0011` |
| `RREADY`, `BREADY` | always 1 |

The SoC only ever issues these transactions:

- **Line read**: `ARLEN` is 7, the address is the 64-byte line base.
- **Uncached read** (a ROM word, or a non-cacheable DRAM access): `ARLEN` is 0,
  and the address is aligned down to 8 bytes.
- **Write**: one INCR burst inside one 64-byte line, covering the lanes whose
  strobe is set: `AWADDR` is the line base plus 8 times the first lane, and
  `AWLEN` is the last lane minus the first lane. A whole-line write-back has
  `AWLEN` 7; a single store has `AWLEN` 0. `WSTRB` carries the byte enables.

#### What the slave must provide

- Accept the requests above. WRAP and FIXED bursts, exclusive access and
  narrow transfers are not used.
- `ARID` is the number of the `mem_ctrl` slot that issued the read. Slots are
  numbered: data slot of hart `h` is `h`, instruction slot of hart `h` is
  `N_HARTS + h`, and the debug System Bus Access slot is `2 * N_HARTS`. A slot
  has at most one read outstanding. Reads with different IDs may complete in any
  order; reads with the same ID must return in order.
- `AWID` is always 0, so writes must complete and be observed in order.
- A read of a line must observe every earlier write the SoC has issued to that
  line. The SoC enforces this itself: it holds back a read of a line while a
  write to the same line has not received its `B` response.
- Hold the response data stable per the AXI rules. The master never stalls `R`
  or `B`.
- The master does not depend on more than one outstanding transaction, so a
  simple slave works. `src/peripheral/axi4_sram.veryl` is an example: a
  burst-at-a-time slave over a dual-port RAM, usable as an FPGA block RAM front
  end or for bring-up.

An error response (`RRESP` or `BRESP` not OKAY) does not raise an access fault in
the core. It sets a sticky bit of `o_axi_err`: bit 0 for `RRESP`, bit 1 for
`BRESP`, bit 2 for a protocol fault of the slave (an unexpected `R` beat, a
misplaced `RLAST`, or `BID` other than 0). `o_axi_err` is 0 in a healthy system.

Both DRAM and boot ROM are reached through this port; see the memory map.

### Interrupts and time

| Port | Direction | Meaning |
|---|---|---|
| `i_ext_irq_src` | in, 32 bits | External interrupt sources, ORed into the PLIC sources. Bit 10 is used by the UART, so use the other bits (1 to 31 are valid PLIC sources; bit 0 is reserved). |
| `i_mtime_tick` | in | One `mtime` tick per cycle it is high, when `MTIME_SRC` is `MTIME_EXTERNAL` |

### UART

`o_uart_tx_valid` and `o_uart_tx_data[7:0]` pulse when software writes the UART
transmit register. The UART has no receive pin: its receive side is tied off.

### Debug

`i_dm_rst` and the APB slave port `i_dm_psel`, `i_dm_penable`, `i_dm_pwrite`,
`i_dm_paddr[8:0]`, `i_dm_pwdata[31:0]`, `i_dm_pstrb[3:0]`, `i_dm_pprot[2:0]`,
`o_dm_pready`, `o_dm_prdata[31:0]`, `o_dm_pslverr`. See [Debug](#debug).

### Observation outputs

| Port | Content |
|---|---|
| `o_retire` | `retire_pkg::RetireRec`, indexed `hart * RET_LANES + lane` (`soc_pkg::RET_LANES` is 4; a core with fewer lanes leaves the upper lanes invalid) |
| `o_retire_dm` | Per hart: this cycle's retire records were retired in Debug Mode |
| `o_irq_evt` | Per hart: interrupt events |
| `o_core_chk` | Per hart: sticky invariant-checker flags (`soc_pkg::CHK_W` bits); all zero in a correct run |
| `o_core_perf` | Per hart: event wires (`soc_pkg::PERF_W` bits) |
| `o_mc_perf` | `soc_pkg::McPerf`: event wires of the AXI master |
| `o_io_obs` | Two `soc_pkg::IoObs`: the device-side CLINT, PLIC or UART access of this cycle, `[0]` a read and `[1]` a write |
| `o_dm_obs` | `soc_pkg::DmObs`: Debug Module events |
| `o_axi_err` | Sticky AXI error flags |

Leave the observation outputs unconnected in a product design. Testbenches use
them to compare retire streams and to check invariants.

### Verification inputs

`i_dbg_retire_limit_en`, `i_dbg_retire_limit`, `i_dbg_irq_mask` and
`i_dbg_irq_allow` (one bit or one 64-bit value per hart) let a testbench replay a
reference interrupt schedule. They default to 0, which disables them, and are
unrelated to the Debug Module.

## Memory map and PMA

Every physical address decision in the core and the SoC (cacheable or not, which
atomics are allowed, whether the address is backed, whether fetch is permitted,
whether the access goes to AXI or to a device) is made by one function,
`pma_check`, over the table `PMA_REGIONS`. A region is a naturally aligned
power-of-two block: an address hits when `(pa & mask) == base`. An address that
hits no region is a hole: accessing it raises an access fault.

`pma_pkg::PmaRegion` is `{base, mask, attr}`, and `attr` holds:

| Field | Meaning |
|---|---|
| `target` | `DRAM`, `ROM`, `IO` or `DEBUG` |
| `backed` | The region exists |
| `cacheable`, `coherent` | Cacheable in the L1 caches; kept coherent by the directory |
| `executable` | Instruction fetch allowed |
| `amo` | `NONE`, `LRSC` or `FULL` |
| `idempotent` | A speculative read is allowed |
| `io_ordered` | Strongly ordered, non-speculative |
| `misaligned_ok` | Misaligned accesses are handled in hardware |
| `pte_ok` | Page tables may live here |
| `cbo_ok` | Cache-block operations are allowed |

The table must satisfy these rules (`pma_table_err` returns a bit per violated
rule, 0 for a legal table; the SoC does not check it, so call it in a test):

- Each region is a power-of-two size of at least 4 KiB, aligned to its size.
- Regions do not overlap.
- `executable` requires `idempotent`.
- `pte_ok` requires `cacheable` and `coherent`.
- `amo` other than `NONE` requires `cacheable`.

`DRAM` and `ROM` regions are served through the AXI4 port. `IO` and `DEBUG`
regions are served inside the SoC. The three devices are decoded by fixed address
windows that your table must agree with.

| Region | Base | Size in the reference table | Target |
|---|---|---|---|
| Boot ROM | `0x0000_0000` | 16 KiB | `ROM`, executable, uncached |
| Debug code | `DM_BASE` (`0x4000`) | 4 KiB | `DEBUG`, executable |
| Debug data | `DM_BASE + 0x1000` | 4 KiB | `DEBUG`, io-ordered |
| CLINT | `0x0200_0000` | 64 KiB | `IO` |
| PLIC | `0x0C00_0000` | 4 MiB | `IO` |
| UART | `0x1000_0000` | 4 KiB | `IO` |
| DRAM | `0x8000_0000` | 32 MiB in the Linux boot harness | `DRAM`, cacheable, coherent, executable, full atomics |

The reference tables are `MAP_BOOT` (with the boot ROM, for Linux) and
`MAP_ARCH` (no ROM, 4 MiB of DRAM, for the architecture tests) in
`tb/tb_platform_pkg.veryl`. Copy one and change the sizes to match your memory.
The device windows (CLINT at `0x0200_0000`, PLIC at `0x0C00_0000`, UART at
`0x1000_0000`) are fixed in the SoC; only their PMA attributes come from the
table. A debug region must exist at `DM_BASE` (code) and `DM_BASE + 0x1000`
(data) with target `DEBUG`, or the Debug Module cannot run.

### Devices

| Device | Registers |
|---|---|
| CLINT (SiFive layout) | `msip[h]` at `0x0000 + 4*h`; `mtimecmp[h]` at `0x4000 + 8*h`; `mtime` at `0xBFF8` |
| PLIC | priority of source `s` at `0x000000 + 4*s`; pending at `0x001000`; enable of context `c` at `0x002000 + 0x80*c`; threshold of context `c` at `0x200000 + 0x1000*c`; claim/complete at `0x200004 + 0x1000*c`. Context `2*h` is hart `h` machine mode, `2*h+1` supervisor mode. 31 sources, 3-bit priorities. |
| UART (16550 subset) | THR/RBR at offset 0, IER at 1, IIR at 2, LSR at 5. Transmit only. |

## Time and interrupts

The CLINT produces `mtime`, the timer interrupt (`mtimecmp`) and the software
interrupt (`msip`) of each hart. The PLIC produces the machine and supervisor
external interrupt of each hart from the UART (source 10) and `i_ext_irq_src`.

`MTIME_SRC` selects what advances `mtime`:

| Value | Behavior |
|---|---|
| `MTIME_CYCLE` | One tick every `MTIME_DIV` cycles. With the default `MTIME_DIV = 10` the CLINT's own prescaler is used: a 100 MHz clock gives the 10 MHz time base that the Linux device trees declare (`timebase-frequency = <10000000>`). |
| `MTIME_INSTRET` | One tick per `MTIME_DIV` retired instructions of hart 0. Needs `N_HARTS = 1` and `MTIME_DIV` at least the number of retire lanes. It makes the time seen by software independent of microarchitectural timing, which is what a lockstep comparison needs. |
| `MTIME_EXTERNAL` | One tick per cycle in which `i_mtime_tick` is high |
| `MTIME_OFF` | `mtime` stays 0 |

## Instantiating the SoC

A minimal instance, with a 4-hart W2 SoC and the observation outputs left open:

```veryl
inst u_soc: heliodor_soc_smp #(
    N_HARTS    : 4                                ,
    CORE       : soc_pkg::CoreSel::W2             ,
    PMA_N      : tb_platform_pkg::MAP_BOOT_N      ,
    PMA_REGIONS: tb_platform_pkg::MAP_BOOT        ,
) (
    clk                               ,
    rst                               ,
    o_axi_arvalid  : axi_arvalid      ,
    i_axi_arready  : axi_arready      ,
    // ... the other AXI4 signals ...
    o_uart_tx_valid: uart_tx_valid    ,
    o_uart_tx_data : uart_tx_data     ,
    i_ext_irq_src  : ext_irq          ,
    i_dm_rst       : rst              ,
    i_dm_psel      : 1'b0             ,
    i_dm_penable   : 1'b0             ,
    i_dm_pwrite    : 1'b0             ,
    i_dm_paddr     : 9'd0             ,
    i_dm_pwdata    : 32'd0            ,
    i_dm_pstrb     : 4'd0             ,
    i_dm_pprot     : 3'd0             ,
    o_dm_pready    : _                ,
    o_dm_prdata    : _                ,
    o_dm_pslverr   : _                ,
    // observation outputs: _
);
```

`tb/boot_soc_harness.veryl` is a complete, working integration: the SoC with an
AXI4 slave model holding DRAM and ROM, used by the Linux boot tests.
`tb/gdb_soc_harness.veryl` is the same with the debug port brought out. The
generated SystemVerilog uses the project prefix: the module is
`heliodor_soc_smp`, and its package of constants is `heliodor_soc_pkg`.

## Debug

The Debug Module implements Debug Specification 1.0: halt and resume, single
step, Access Register commands for GPRs, FPRs and CSRs, the program buffer,
System Bus Access, `ndmreset` and `hartreset`, and halt and resume groups. One
Debug Module serves all harts. There is no JTAG in the design: the debug
interface is an APB4 slave port, and a JTAG Debug Transport Module is the
integrator's to add.

### The APB port

- `paddr[8:2]` is the DMI address (0x00 to 0x7F); `paddr[1:0]` is ignored.
- Every transfer takes one wait state: `pready` is 0 in the first access cycle
  and 1 in the second.
- A write whose `pstrb` is not `4'hF` is dropped and answers `pslverr = 1`.
- A DMI address that does not exist reads 0, and writes to it are dropped.
- `i_dm_rst` resets the Debug Module and the APB logic. Pulse it at power-on only:
  `ndmreset` and `hartreset` do not reset it.
- `pprot` is ignored.
- Clock-domain crossing, `psel` generation and the JTAG DTM are outside the SoC.

When no debugger is attached, tie `i_dm_psel`, `i_dm_penable` and `i_dm_pwrite`
to 0. With the port idle, the SoC behaves exactly as if there were no Debug
Module.

### Connecting OpenOCD and GDB in simulation

The repository has a reference JTAG DTM and a remote-bitbang server for
Verilator: `sim/verilator/jtag_dtm.sv`, `sim/verilator/rbb_dpi.c`, and the
wrapper `sim/verilator/tb_soc_dm.sv`. The DTM has IDCODE `0x10000a03`, a 5-bit
instruction register, `dtmcs` version 1 with 7 address bits, and runs at most at
half the clock frequency. These files are testbench code, not part of the design.

Build the simulator for a 1-hart W2 SoC, then start it and connect OpenOCD:

```bash
source toolchain/env.sh
veryl build
verilator --binary --top-module tb_soc_dm -f heliodor.f \
          sim/verilator/jtag_dtm.sv sim/verilator/tb_soc_dm.sv sim/verilator/rbb_dpi.c \
          --timing -Wno-fatal -O1 -j 4 -GN_HARTS=1 -GW4=0 \
          --Mdir sim/verilator/build_dm_w2_n1 -o tb_soc_dm
sim/verilator/build_dm_w2_n1/tb_soc_dm     # prints the remote-bitbang port
```

The wrapper's parameters are `N_HARTS`, `W4` (0 for the W2 core, 1 for W4) and
`AXI_SEL` (the AXI slave timing of the testbench). It prints
`Listening for remote bitbang connection on port N.`; the run ends when the
debugger quits.

In a second shell, start OpenOCD with the configuration in
`test/debug/openocd/` (`heliodor-1.cfg` for one hart, `heliodor-4.cfg` for four).
The configuration reads its settings from environment variables:

```bash
source toolchain/env.sh      # openocd and riscv64-unknown-elf-gdb come from `toolchain/fetch.sh debug`
REMOTE_BITBANG_HOST=localhost REMOTE_BITBANG_PORT=<port> \
WORK_AREA=0x80000000 USE_FREERTOS=0 HELIODOR_CMD_TIMEOUT=300 \
openocd -f test/debug/openocd/heliodor-1.cfg
```

Then connect GDB to OpenOCD's GDB port (3333 by default):

```bash
riscv64-unknown-elf-gdb -ex 'target extended-remote :3333'
```

The simulator is slow, so the OpenOCD command timeout is long.

`test/debug/run_ocd.sh <build_dir> <cfg> <script.tcl> <pass_marker>` starts the
simulator and OpenOCD, runs a Tcl script, and stops both, which is the quickest
way to run a scripted check. `test/debug/run_gg.sh` runs the RISC-V debug test
suite (`gdbserver.py`) against the simulator.

### Debug memory

The Debug Module executes abstract commands by placing instructions in debug
memory and letting the halted hart run them. Debug memory is two 4 KiB regions at
`DM_BASE` (code: the debug ROM, command words and the program buffer) and
`DM_BASE + 0x1000` (data and per-hart flags). It is visible only in Debug Mode;
anywhere else it raises an access fault. Your PMA table must map both regions
with target `DEBUG` (see [Memory map and PMA](#memory-map-and-pma)).

### Reset

`ndmreset` resets everything except the Debug Module and the APB logic. It waits
for the AXI port to go idle before it takes effect. `hartreset` resets one hart's
core domain after the hart has quiesced; its L1 data cache is a coherence agent
and keeps its contents.
