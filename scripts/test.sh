#!/bin/sh
# Builds tools/tester.nim and hands over to it; see that file for the rules.
# SUITE=fast|full|stress, TESTS="tests/relay tests/app/treadyio.nim", WORKERS="1 4".
set -eu
cd "$(dirname "$0")/.."
NIMONY=${NIMONY:-nimony}
BUILD_DIR=${BUILD_DIR:-build/test}
mkdir -p "$BUILD_DIR"
BUILD_DIR=$(cd "$BUILD_DIR" && pwd)
TESTER=$BUILD_DIR/tester
if [ ! -x "$TESTER" ] || [ tools/tester.nim -nt "$TESTER" ]; then
  XDG_CACHE_HOME="$BUILD_DIR/c-cache" "$NIMONY" c --ff --nimcache:"$BUILD_DIR/cache-tester" \
    -o:"$TESTER" tools/tester.nim >"$BUILD_DIR/tester.log" 2>&1 || { cat "$BUILD_DIR/tester.log" >&2; exit 1; }
fi
set -- --nimony:"$NIMONY" --build:"$BUILD_DIR" --workers:"${WORKERS:-1}"
for flag in ${NIMFLAGS:-}; do set -- "$@" --flag:"$flag"; done
if [ -n "${ARCH:-}" ]; then set -- "$@" "--flag:--passC:-arch $ARCH" "--flag:--passL:-arch $ARCH"; fi
if [ "${SANITIZE:-0}" = 1 ]; then
  # UBSan otherwise recovers and lets a failing sanitizer run print "ok".
  export UBSAN_OPTIONS=${UBSAN_OPTIONS:-halt_on_error=1}
  for flag in --passC:-fsanitize=address,undefined --passC:-DMI_TRACK_ASAN=1 --passC:-fno-omit-frame-pointer --passL:-fsanitize=address,undefined; do
    set -- "$@" --flag:"$flag"
  done
fi
if [ -n "${TESTS:-}" ]; then exec "$TESTER" "$@" $TESTS; fi
case "${SUITE:-fast}" in
  full) exec "$TESTER" "$@" tests examples ;;
  *) exec "$TESTER" "$@" --suite:"${SUITE:-fast}" ;;
esac
