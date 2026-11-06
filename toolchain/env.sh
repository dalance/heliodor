# Source this to put the fetched toolchains on PATH and set ACT4 env:
#     source toolchain/env.sh
#
# Safe to source from any directory. Only prepends dirs that actually exist, so
# it works even if you've only fetched some components.

_tc_root="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

_tc_prepend() { [ -d "$1" ] && case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH";; esac; }

# Compilers (riscv-collab archives have bin/ at the root after strip).
_tc_prepend "$_tc_root/elf/bin"
_tc_prepend "$_tc_root/linux/bin"
# Sail (fetched with strip=1 → bin/ at the root).
_tc_prepend "$_tc_root/sail"
_tc_prepend "$_tc_root/sail/bin"
# uv: single binary at the root after strip.
_tc_prepend "$_tc_root/uv"
# Debug flow (source-built by `fetch.sh debug`).
_tc_prepend "$_tc_root/spike/bin"
_tc_prepend "$_tc_root/openocd/bin"
_tc_prepend "$_tc_root/gdb/bin"
export PATH

# ACT4 Python (uv) + Ruby/UDB (bundler) caches must be writable. Keep them under
# the gitignored build area so they never pollute $HOME or a read-only system gem dir.
export UV_CACHE_DIR="${UV_CACHE_DIR:-$_tc_root/.uv-cache}"
export BUNDLE_PATH="${BUNDLE_PATH:-$_tc_root/.bundle}"
# uv installs the framework's pinned Python (.python-version) here.
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$_tc_root/.uv-python}"

# Convenience handles consumed by the test/act and test/linux build scripts.
export RISCV_ELF_PREFIX="${RISCV_ELF_PREFIX:-riscv64-unknown-elf-}"
export RISCV_LINUX_PREFIX="${RISCV_LINUX_PREFIX:-riscv64-unknown-linux-gnu-}"

unset -f _tc_prepend
