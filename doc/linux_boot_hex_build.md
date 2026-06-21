# Linux Boot Hex Generation — moved

The Linux boot image build has been consolidated under **`test/linux/`**:

- sources: `test/linux/{fw,init,dts,configs}/`
- build:   `test/linux/build.sh` (uses the pinned `toolchain/linux`)
- docs:    `test/linux/README.md`

The toolchain is fetched via `toolchain/fetch.sh linux` (see `toolchain/README.md`).
The pinned linux-gnu toolchain (binutils 2.43) has RVV `as`, `ld -shared`, and
`ld` ≥ 2.38, so the old elf-CC/linux-LD mix and the two kernel Kconfig
workarounds are no longer needed.

The previous, detailed recipe (mixed-toolchain steps + symptom→cause table) is
preserved in git history of this file.
