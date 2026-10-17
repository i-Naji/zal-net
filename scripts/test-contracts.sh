#!/bin/sh
# Compile-time ownership and plain-data contracts.
set -eu
cd "$(dirname "$0")/.."
NIMONY=${NIMONY:-nimony}
OUT=${BUILD_DIR:-build/contracts}
mkdir -p "$OUT"
reject() {
  source=$1
  message=$2
  name=$(basename "$source" .nim)
  if "$NIMONY" c --ff --mm:atomicArc --path:src --nimcache:"$OUT/cache-$name" \
      -o:"$OUT/$name" "$source" >"$OUT/$name.log" 2>&1; then
    echo "FAIL accepted $source"
    exit 1
  fi
  if ! grep -q "$message" "$OUT/$name.log"; then
    cat "$OUT/$name.log"
    exit 1
  fi
  echo "ok   rejects $source"
}
for name in sequence_value string_value reference_value closure_value nested_value; do
  reject "tests/plain-data/$name.nim" 'cross-thread byte copies require plain data'
done
for name in resize reader; do
  reject "tests/borrows/$name.nim" 'is borrowed and cannot be mutated'
done
