#!/bin/sh
# Contract lane for the std-only port. Refuses patched Nimony source trees.
# Usage: scripts/test-stdlib.sh [clean pinned Nimony checkout]
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT=${1:-$HERE/build/std-unmodified}
ROOT=$(CDPATH= cd -- "$ROOT" && pwd)
PIN=$(cat "$HERE/ci/nimony.ref")
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$PIN" ] || {
  echo "test-stdlib: compiler checkout must match ci/nimony.ref" >&2; exit 1;
}
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all -- lib src)" ] || {
  echo "test-stdlib: requires unchanged compiler and standard library sources" >&2; exit 1;
}
cd "$HERE"
MODE=${MODE:-normal}
OUT=$HERE/build/stdlib-contract/$MODE
mkdir -p "$OUT"
set -- --mm:atomicArc -d:useMimalloc --path:src
case "$MODE" in
  normal) ;;
  release) set -- "$@" -d:release ;;
  asan) set -- "$@" --passC:-fsanitize=address,undefined --passC:-DMI_TRACK_ASAN=1 --passC:-fno-omit-frame-pointer --passL:-fsanitize=address,undefined ;;
  *) echo "unknown MODE: $MODE" >&2; exit 2 ;;
esac
for TEST in treadiness tadmission tdrain tcontinuations; do
  XDG_CACHE_HOME="$OUT/c-cache-$TEST" "$ROOT/bin/nimony" c --ff "$@" --nimcache:"$OUT/cache-$TEST" -o:"$OUT/$TEST" \
    "tests/stdlib/$TEST.nim" >"$OUT/$TEST-build.log" 2>&1 || {
      cat "$OUT/$TEST-build.log" >&2; exit 1;
    }
  python3 - "$OUT/$TEST" <<'PY'
import subprocess, sys
try:
    watchdog = 90 if sys.argv[1].endswith("tcontinuations") else 45
    result = subprocess.run([sys.argv[1]], timeout=watchdog)
except subprocess.TimeoutExpired:
    print('FAIL: contract exceeded its watchdog', file=sys.stderr)
    sys.exit(1)
sys.exit(result.returncode)
PY
done
# A non-atomic memory model must not compile worker-safe handles.
if "$ROOT/bin/nimony" c --ff --mm:arc --path:src \
  --nimcache:"$OUT/cache-reject-arc" -o:"$OUT/reject-arc" \
  tests/stdlib/tadmission.nim >"$OUT/reject-arc.log" 2>&1; then
  echo 'FAIL: admission accepted non-atomic ARC' >&2; exit 1
fi
grep -q 'Worker-safe resource handles require --mm:atomicArc' "$OUT/reject-arc.log"
echo 'PASS rejects non-atomic ARC'
