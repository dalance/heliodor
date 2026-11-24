#!/usr/bin/env bash
# Download + extract pinned prebuilt toolchain components into toolchain/<tool>/.
#
# Usage:
#   ./fetch.sh all          # fetch everything declared in versions.env
#   ./fetch.sh elf          # fetch one component (elf | linux | sail | uv | mdbook)
#   ./fetch.sh book         # mdbook + mdbook-i18n-helpers (built from source) for book/
#   ./fetch.sh debug        # build spike + openocd + gdb from source (MD debug flow)
#   ./fetch.sh spike        # build one of spike | openocd | gdb
#   ./fetch.sh glt          # clone litmus-tests-riscv + build herd7 (GLT)
#   ./fetch.sh elf linux    # fetch several
#
# Resolves the release asset via the GitHub API (so the exact dated asset name
# need not be hard-coded), verifies sha256 if pinned in versions.env, and
# extracts into toolchain/<tool>/ (gitignored). Re-running is idempotent: a tool
# whose marker file already exists is skipped unless FORCE=1.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$here/versions.env"

API="https://api.github.com"
: "${FORCE:=0}"

# Resolve a release asset's browser_download_url by repo, tag, and a glob.
resolve_url() {
  local repo="$1" tag="$2" glob="$3"
  local hdr=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && hdr=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL "${hdr[@]}" "$API/repos/$repo/releases/tags/$tag" \
    | grep -oE '"browser_download_url": *"[^"]+"' \
    | sed -E 's/.*"(https[^"]+)"/\1/' \
    | grep -E "/${glob//\*/.*}\$" \
    | head -1
}

fetch_one() {
  local name="$1"
  local up="${name^^}"
  local repo tag glob sha strip
  repo="$(eval echo "\${${up}_REPO}")"
  tag="$(eval echo "\${${up}_TAG}")"
  glob="$(eval echo "\${${up}_GLOB}")"
  sha="$(eval echo "\${${up}_SHA256:-}")"
  strip="$(eval echo "\${${up}_STRIP:-0}")"

  local dest="$here/$name"
  if [[ -e "$dest/.fetched" && "$FORCE" != "1" ]]; then
    echo "[$name] already present ($dest) — skip (FORCE=1 to refetch)"
    return 0
  fi

  echo "[$name] resolving $repo @ $tag ($glob) ..."
  local url
  url="$(resolve_url "$repo" "$tag" "$glob")"
  [[ -n "$url" ]] || { echo "[$name] ERROR: no asset matched '$glob' in $repo@$tag" >&2; return 1; }
  echo "[$name] url: $url"

  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  local arc="$tmp/$(basename "$url")"
  curl -fSL --retry 3 -o "$arc" "$url"

  local got; got="$(sha256sum "$arc" | awk '{print $1}')"
  if [[ -n "$sha" ]]; then
    [[ "$got" == "$sha" ]] || { echo "[$name] ERROR sha256 mismatch: got $got want $sha" >&2; return 1; }
    echo "[$name] sha256 OK"
  else
    echo "[$name] sha256 (pin this in versions.env as ${up}_SHA256): $got"
  fi

  rm -rf "$dest"; mkdir -p "$dest"
  echo "[$name] extracting (strip=$strip) ..."
  tar -xf "$arc" -C "$dest" --strip-components="$strip"
  date -u +%FT%TZ > "$dest/.fetched"
  echo "[$name] done -> $dest"
}

# Source-built tools (spike, openocd, gdb): pinned commit or tarball, built into
# toolchain/<tool>/ with the sources under toolchain/src/ (both gitignored).
# Needs gcc/g++ >= 11, make, autotools (openocd), dtc + boost (spike),
# gmp/mpfr/ncurses/zlib/expat -devel (gdb). Nothing is installed system-wide.
JOBS="${JOBS:-$(nproc)}"

git_checkout() {
  local url="$1" commit="$2" dir="$3"
  rm -rf "$dir"; git init -q "$dir"
  git -C "$dir" remote add origin "$url"
  git -C "$dir" fetch -q --depth 1 origin "$commit"
  git -C "$dir" checkout -q FETCH_HEAD
}

build_spike() {
  local src="$here/src/spike" dest="$here/spike"
  git_checkout "$SPIKE_GIT" "$SPIKE_COMMIT" "$src"
  git -C "$src" submodule update --init --depth 1
  mkdir -p "$src/build"
  ( cd "$src/build" && ../configure --prefix="$dest" && make -j"$JOBS" && make install )
}

build_openocd() {
  local src="$here/src/openocd" dest="$here/openocd"
  git_checkout "$OPENOCD_GIT" "$OPENOCD_COMMIT" "$src"
  # Only jimtcl is needed; libjaylink lives on gitlab and serves J-Link only.
  git -C "$src" submodule update --init --depth 1 jimtcl
  # automake wants README, git checkouts only carry README.md.
  ( cd "$src" && cp README.md README && ./bootstrap nosubmodule \
    && ./configure --prefix="$dest" --disable-werror --disable-internal-libjaylink --enable-internal-jimtcl \
         --enable-remote-bitbang --enable-jtag_dpi \
    && make -j"$JOBS" && make install )
}

build_gdb() {
  local src="$here/src/gdb" dest="$here/gdb" tmp; tmp="$(mktemp -d)"
  curl -fSL --retry 3 -o "$tmp/gdb.tar.xz" "$GDB_URL"
  local got; got="$(sha256sum "$tmp/gdb.tar.xz" | awk '{print $1}')"
  if [[ -n "$GDB_SHA256" ]]; then
    [[ "$got" == "$GDB_SHA256" ]] || { echo "[gdb] ERROR sha256 mismatch: got $got want $GDB_SHA256" >&2; return 1; }
  else
    echo "[gdb] sha256 (pin this in versions.env as GDB_SHA256): $got"
  fi
  rm -rf "$src"; mkdir -p "$src/build"
  tar -xf "$tmp/gdb.tar.xz" -C "$src" --strip-components=1
  rm -rf "$tmp"
  ( cd "$src/build" && ../configure --prefix="$dest" --target=riscv64-unknown-elf \
      --with-python=no --disable-werror --disable-binutils --disable-ld \
      --disable-gas --disable-gprof --disable-sim --disable-gold \
    && make -j"$JOBS" all-gdb && make install-gdb )
}

build_herd() {
  local dest="$here/herd" src="$here/src/herdtools7"
  mkdir -p "$dest/bin"
  curl -fSL --retry 3 -o "$dest/bin/opam" "$OPAM_URL"
  local got; got="$(sha256sum "$dest/bin/opam" | awk '{print $1}')"
  [[ "$got" == "$OPAM_SHA256" ]] || { echo "[herd] ERROR opam sha256 mismatch: got $got" >&2; return 1; }
  chmod +x "$dest/bin/opam"
  export OPAMROOT="$dest/opam" OPAMYES=1 OPAMCOLOR=never DUNE_CACHE=disabled XDG_CACHE_HOME="$dest/.cache"
  local opam="$dest/bin/opam" ocaml pkgs
  read -r ocaml pkgs <<< "$OCAML_PKGS"
  [[ -d "$OPAMROOT" ]] || "$opam" init --bare --disable-sandboxing -n default https://opam.ocaml.org
  "$opam" switch list -s | grep -qx herd || "$opam" switch create herd "$ocaml" -j"$JOBS"
  # shellcheck disable=SC2086
  "$opam" install --switch herd -j"$JOBS" $pkgs
  git_checkout "$HERD_GIT" "$HERD_COMMIT" "$src"
  ( eval "$("$opam" env --switch herd --set-switch)" && cd "$src" \
    && make all PREFIX="$dest" -j"$JOBS" && make install PREFIX="$dest" )
}

fetch_litmus() {
  local dest="$here/../test/glt/upstream/litmus-tests-riscv"
  if [[ -e "$dest/.fetched" && "$FORCE" != "1" ]]; then
    echo "[litmus] already present ($dest) — skip (FORCE=1 to refetch)"
    return 0
  fi
  git_checkout "$LITMUS_GIT" "$LITMUS_COMMIT" "$dest"
  date -u +%FT%TZ > "$dest/.fetched"
  echo "[litmus] done -> $dest"
}

# mdbook-i18n-helpers: pinned crates.io source (sha256-verified), built with the
# Cargo.lock it ships. Installs mdbook-gettext and mdbook-xgettext into
# toolchain/i18n/bin. Needs cargo.
build_i18n() {
  local src="$here/src/i18n" dest="$here/i18n" tmp; tmp="$(mktemp -d)"
  local name="mdbook-i18n-helpers-$I18N_VERSION"
  curl -fSL --retry 3 -o "$tmp/crate.tar.gz" "https://static.crates.io/crates/mdbook-i18n-helpers/$name.crate"
  local got; got="$(sha256sum "$tmp/crate.tar.gz" | awk '{print $1}')"
  if [[ -n "$I18N_SHA256" ]]; then
    [[ "$got" == "$I18N_SHA256" ]] || { echo "[i18n] ERROR sha256 mismatch: got $got want $I18N_SHA256" >&2; return 1; }
  else
    echo "[i18n] sha256 (pin this in versions.env as I18N_SHA256): $got"
  fi
  rm -rf "$src"; mkdir -p "$src"
  tar -xzf "$tmp/crate.tar.gz" -C "$src" --strip-components=1
  rm -rf "$tmp"
  [[ -f "$src/Cargo.lock" ]] || { echo "[i18n] ERROR: crate ships no Cargo.lock" >&2; return 1; }
  rm -rf "$dest"; mkdir -p "$dest/bin"
  ( cd "$src" && cargo build --release --locked --bins \
    && cp target/release/mdbook-gettext target/release/mdbook-xgettext "$dest/bin/" )
}

build_one() {
  local name="$1" dest="$here/$1"
  if [[ -e "$dest/.fetched" && "$FORCE" != "1" ]]; then
    echo "[$name] already present ($dest) — skip (FORCE=1 to rebuild)"
    return 0
  fi
  echo "[$name] building from source ..."
  "build_$name" || return 1
  date -u +%FT%TZ > "$dest/.fetched"
  echo "[$name] done -> $dest"
}

targets=("$@")
[[ ${#targets[@]} -eq 0 ]] && targets=(all)
[[ "${targets[0]}" == "all" ]] && targets=(elf linux sail uv)
[[ "${targets[0]}" == "debug" ]] && targets=(spike openocd gdb)
[[ "${targets[0]}" == "glt" ]] && targets=(litmus herd)
[[ "${targets[0]}" == "book" ]] && targets=(mdbook i18n)
rc=0
for t in "${targets[@]}"; do
  case "$t" in
    spike|openocd|gdb|herd|i18n) build_one "$t" || { echo "[$t] FAILED" >&2; rc=1; } ;;
    litmus) fetch_litmus || { echo "[$t] FAILED" >&2; rc=1; } ;;
    *) fetch_one "$t" || { echo "[$t] FAILED" >&2; rc=1; } ;;
  esac
done
[[ $rc -eq 0 ]] || echo "(some components failed — see above)" >&2

echo
echo "Now: source toolchain/env.sh   # puts the tools on PATH"
exit "$rc"
