import std/[assertions, atomics, syncio]
import zal_net/rt
import zal_net/private/backend/stdrt
from zal_net/private/sys/sock import sleepUs

var calls: int
var anchor = default(CoroutineBase)

proc completion(frame: ptr CoroutineBase): Continuation {.nimcall.} =
  let count = atomicFetchAdd(calls, 1, moRelaxed) + 1
  sleepUs(1000)
  if count < 300:
    result = Continuation(fn: completion, env: frame)
  else:
    result = default(Continuation)

proc root() {.passive.} =
  requestStop()

initRuntime()
assert beTryRoot(root(), Continuation(fn: completion, env: addr anchor))
drainRuntime()
assert runtimeFinished()
assert atomicLoad(calls, moAcquire) == 300
echo "PASS root completion drained across continuation batches"
