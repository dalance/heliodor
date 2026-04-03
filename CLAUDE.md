# Heliodor

RISC-V processor core written in [Veryl](https://veryl-lang.org/).
The ultimate goal is a Linux-capable RV64GC core.

## Veryl Compiler

Use the Veryl compiler from the `veryl/` submodule — do **not** use a system-installed version.

```bash
cd veryl && cargo build                          # debug build
cd veryl && cargo build --profile release-verylup # fast release build (no LTO, parallel codegen)
cd veryl && cargo build --release                 # full release build (slow, max optimization)
```

- **Fast release build**: `veryl/target/release-verylup/veryl` — use for heliodor development and testing. Much faster to compile than `--release` (no LTO, 256 codegen units) while still being optimized.
- **Debug build**: `veryl/target/debug/veryl` — use only when debugging the Veryl compiler/simulator itself.
- When modifying the simulator, use debug builds first to catch compilation errors quickly, then switch to `--profile release-verylup` for verification.

Key commands:

| Command       | Description                              |
|---------------|------------------------------------------|
| `veryl check` | Analyze (type check, lint)               |
| `veryl build` | Transpile to SystemVerilog               |
| `veryl fmt`   | Format source files                      |
| `veryl test`  | Run native testbenches (uses debug binary)|
| `veryl clean` | Remove build artifacts                   |

The compiler itself may be debugged or patched as needed.
Refer to `veryl/testcases/veryl/` for language feature examples.

## Directory Structure

```
heliodor/
├── CLAUDE.md
├── Veryl.toml              # Project configuration
├── src/
│   ├── core/               # Pipeline stages, decode, ALU, etc.
│   ├── cache/              # I-Cache / D-Cache
│   ├── mmu/                # MMU (Sv39 / Sv48)
│   ├── peripheral/         # UART, CLINT, PLIC, etc.
│   └── pkg/                # Shared packages & type definitions
├── tb/                     # Testbenches (Veryl native test)
├── test/                   # RISC-V ISA test programs
├── doc/                    # Documentation
└── veryl/                  # Veryl compiler (git submodule)
```

## Development Conventions

- **Language**: Veryl (transpiles to SystemVerilog)
- **Comments & documentation**: English
- **Testing**: Veryl native testbench — always run **both** JIT on and off to catch simulator bugs early:
  ```bash
  veryl test                          # JIT on (default), all tests
  veryl test --disable-jit            # JIT off, all tests
  veryl test --test test_dcache_lbu   # run specific test only (faster for debugging)
  ```
- **Formatting**: `veryl fmt`
- **Veryl compiler/simulator bugs**: Do NOT work around bugs by modifying heliodor source code. Report the issue and fix it in the `veryl/` submodule.

## Development Roadmap

| Phase | Target                                                              |
|-------|---------------------------------------------------------------------|
| 1     | RV64I base integer ISA — basic pipeline                             |
| 2     | M extension (multiply / divide) and pipeline optimization           |
| 3     | Privilege specification (M/S/U modes, CSRs)                         |
| 4     | MMU (Sv39), I-Cache / D-Cache                                       |
| 5     | A extension (atomics), interrupts & exceptions (CLINT / PLIC)       |
| 6     | C extension (compressed instructions)                               |
| 7     | F/D extensions (floating-point) — full GC compliance                |
| 8     | Linux boot integration test                                         |

## Sandbox Restrictions

- **Do NOT use `ps`** to check for running processes. The `ps` command does not work correctly inside the sandbox and produces misleading results (e.g., empty output even when processes are running). Instead, wait for command completion via the shell's return or use the timeout mechanism.

## RISC-V Reference

- **ISA**: RV64GC (`RV64IMAFDCZicsr_Zifencei`)
- **Privilege levels**: Machine / Supervisor / User
- **Virtual memory**: Sv39 (minimum), Sv48 (optional)
