#!/usr/bin/env bash
# Download + extract pinned prebuilt toolchain components into toolchain/<tool>/.
#
# Usage:
#   ./fetch.sh all          # fetch everything declared in versions.env
#   ./fetch.sh elf          # fetch one component (elf | linux | sail | uv)
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

targets=("$@")
[[ ${#targets[@]} -eq 0 ]] && targets=(all)
[[ "${targets[0]}" == "all" ]] && targets=(elf linux sail uv)
for t in "${targets[@]}"; do fetch_one "$t"; done

echo
echo "Now: source toolchain/env.sh   # puts the tools on PATH"
