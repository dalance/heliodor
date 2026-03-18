# Heliodor

RISC-V processor core written in [Veryl](https://veryl-lang.org/).
The ultimate goal is a Linux-capable RV64GC core.

## Veryl Compiler

Use the Veryl compiler from the `veryl/` submodule — do **not** use a system-installed version.

```bash
cd veryl && cargo build --release
```

Binary: `veryl/target/release/veryl`

Key commands:

| Command       | Description                              |
|---------------|------------------------------------------|
| `veryl check` | Analyze (type check, lint)               |
| `veryl build` | Transpile to SystemVerilog               |
| `veryl fmt`   | Format source files                      |
| `veryl test`  | Run native testbenches                   |
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
- **Testing**: Veryl native testbench (`veryl test`)
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

## RISC-V Reference

- **ISA**: RV64GC (`RV64IMAFDCZicsr_Zifencei`)
- **Privilege levels**: Machine / Supervisor / User
- **Virtual memory**: Sv39 (minimum), Sv48 (optional)
