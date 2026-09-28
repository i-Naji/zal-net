#!/bin/sh
set -eu
HERE=$(cd "$(dirname "$0")/.." && pwd)
REF=${NIMONY_REF:-$(cat "$HERE/ci/nimony.ref")}
DIR=${1:-$HERE/build/toolchain}
if [ ! -d "$DIR/.git" ]; then
  git clone --filter=blob:none https://github.com/nim-lang/nimony "$DIR"
fi
cd "$DIR"
head=$(git rev-parse HEAD)
case "$head" in
  "$REF"*) ;;
  *)
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
      echo "nimony-setup: $DIR is at $head with local changes; not moving it to $REF" >&2
      exit 1
    fi
    git fetch -q origin
    git checkout -q "$REF"
    ;;
esac
if [ -n "$(git status --porcelain --untracked-files=all -- lib src)" ]; then
  echo "nimony-setup: use a clean compiler checkout" >&2
  exit 1
fi
git submodule update --init vendor/mimalloc

if [ "${NO_BUILD:-0}" != 1 ]; then
  nim c -r src/hastur/hastur --release build all
fi
echo "nimony-setup: $DIR/bin/nimony at $(git rev-parse --short HEAD)"
