## Tasks and scopes: join, cancel and join, scope waitAll and close with a
## grace period.
import std/assertions
import std/syncio
import std/atomics
import zal_net/rt
import zal_net/raw/io
import zal_net/rt/sync
import zal_net/rt/task
import zal_net/errors

var gRuns: int

proc quick(t: Task; arg: nil pointer): int {.nimcall, passive.} =
  sleepMs(10)
  discard atomicFetchAdd(gRuns, 1, moAcquireRelease)
  result = 7

proc sleeper(t: Task; arg: nil pointer): int {.nimcall, passive.} =
  # Ends early only through its token.
  result = 0
  if sleepUntil(afterMs(10_000), token(t)) == wrCancelled:
    discard atomicFetchAdd(gRuns, 100, moAcquireRelease)

proc main() {.passive.} =
  let a = startTask(quick, nil)
  assert join(a, afterMs(2000)) == wrReady
  assert finished(a)
  assert code(a) == 7
  release(a)
  assert gRuns == 1
  echo "PASS join"

  let b = startTask(sleeper, nil)
  let t0 = monoNow()
  assert cancelAndJoin(b, afterMs(2000)) == wrReady
  assert int64(monoNow()) - int64(t0) < 1_000_000_000
  assert cancelled(b)
  release(b)
  assert gRuns == 101
  echo "PASS cancel and join"

  let s = newScope()
  var i = 0
  while i < 3:
    release(startTask(quick, nil, s))
    i = i + 1
  assert waitAll(s, afterMs(2000)) == wrReady
  assert gRuns == 104
  release(startTask(sleeper, nil, s))
  release(startTask(quick, nil, s))
  assert close(s, afterMs(100)) == wrCancelled
  assert gRuns == 205
  let rejected = startTask(quick, nil, s)
  assert finished(rejected) and code(rejected) == ResourceClosed
  assert cancelled(rejected)
  release(rejected)
  sleepMs(20)
  assert gRuns == 205
  release(s)
  echo "PASS scope waitAll, close and rejection after close"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
