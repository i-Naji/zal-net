#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
NIMONY=${NIMONY:-nimony}
BUILD_DIR=${BUILD_DIR:-build/bench-udp}
WORKERS=${WORKERS:-"1 4"}
SIZES=${SIZES:-"64 1200"}
RUNS=${RUNS:-5}
mkdir -p "$BUILD_DIR"
BUILD_DIR=$(cd "$BUILD_DIR" && pwd)
for size in $SIZES; do
  for mode in scalar batch; do
    name="udp-$mode-$size"
    set -- --ff --mm:atomicArc -d:useMimalloc -d:release --path:src "-d:Size=$size" ${NIMFLAGS:-}
    if [ "$mode" = batch ]; then set -- "$@" -d:benchBatch; fi
    XDG_CACHE_HOME="$BUILD_DIR/c-cache-$name" "$NIMONY" c "$@" \
      --nimcache:"$BUILD_DIR/cache-$name" -o:"$BUILD_DIR/$name" bench/udp.nim \
      >"$BUILD_DIR/$name-build.log" 2>&1 || {
        cat "$BUILD_DIR/$name-build.log" >&2
        exit 1
      }
    if [ "${PRUNE_CASE_CACHES:-0}" = 1 ]; then
      rm -rf "$BUILD_DIR/cache-$name" "$BUILD_DIR/c-cache-$name"
    fi
  done
done
printf 'revision=%s compiler=%s\n' "$(git rev-parse HEAD)" "$NIMONY"
uname -sm
for size in $SIZES; do
  for workers in $WORKERS; do
    for mode in scalar batch; do
      run=0
      while [ "$run" -lt "$RUNS" ]; do
        ZAL_WORKERS=$workers "$BUILD_DIR/udp-$mode-$size"
        run=$((run + 1))
      done
    done
  done
done
