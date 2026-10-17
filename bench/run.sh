#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
NIMONY=${NIMONY:-nimony}
BUILD_DIR=${BUILD_DIR:-build/bench}
WORKERS=${WORKERS:-"1 4"}
RUNS=${RUNS:-5}
mkdir -p "$BUILD_DIR"
BUILD_DIR=$(cd "$BUILD_DIR" && pwd)
for name in transport loopback bulk; do
  source=$name
  set -- --ff --mm:atomicArc -d:useMimalloc -d:release --path:src
  if [ "$name" = bulk ]; then source=loopback; set -- "$@" -d:bulk; fi
  XDG_CACHE_HOME="$BUILD_DIR/c-cache-$name" "$NIMONY" c "$@" \
    --nimcache:"$BUILD_DIR/cache-$name" -o:"$BUILD_DIR/$name" "bench/$source.nim" \
    >"$BUILD_DIR/$name-build.log" 2>&1 || {
      cat "$BUILD_DIR/$name-build.log" >&2
      exit 1
    }
done
printf 'revision=%s compiler=%s\n' "$(git rev-parse HEAD)" "$NIMONY"
uname -sm
"$BUILD_DIR/transport"
for workers in $WORKERS; do
  for name in loopback bulk; do
    run=0
    while [ "$run" -lt "$RUNS" ]; do
      ZAL_WORKERS=$workers "$BUILD_DIR/$name"
      run=$((run + 1))
    done
  done
done
