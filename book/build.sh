#!/usr/bin/env bash
# Build the Heliodor book.
#
#   book/build.sh            # English and Japanese
#   book/build.sh en | ja    # one language
#   book/build.sh pot        # extract book/po/messages.pot (translation source)
#
# Output goes to book/out/<lang>/ (gitignored). Any mdbook warning fails the
# build. The tools come from `toolchain/fetch.sh book`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# env.sh probes optional directories and is not set -e clean.
set +e
# shellcheck source=../toolchain/env.sh
source "$here/../toolchain/env.sh"
set -e
command -v mdbook >/dev/null || { echo "mdbook not found: run toolchain/fetch.sh book" >&2; exit 1; }
command -v mdbook-gettext >/dev/null || { echo "mdbook-gettext not found: run toolchain/fetch.sh book" >&2; exit 1; }

cd "$here"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

run() {
  local rc=0
  "$@" 2>&1 | tee "$log" || rc=$?
  if [[ $rc -ne 0 ]] || grep -q 'WARN' "$log"; then
    echo "book build failed or warned" >&2
    exit 1
  fi
}

build_en() { run env MDBOOK_BOOK__LANGUAGE=en mdbook build -d out/en; }
build_ja() { run env MDBOOK_BOOK__LANGUAGE=ja mdbook build -d out/ja; }
build_pot() {
  command -v mdbook-xgettext >/dev/null || { echo "mdbook-xgettext not found" >&2; exit 1; }
  run env MDBOOK_OUTPUT='{"xgettext": {}}' mdbook build -d po
}

case "${1:-all}" in
  en)  build_en ;;
  ja)  build_ja ;;
  pot) build_pot ;;
  all) build_en; build_ja ;;
  *)   echo "usage: book/build.sh [en|ja|pot|all]" >&2; exit 2 ;;
esac
