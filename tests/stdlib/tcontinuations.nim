## Continuations bypass the bounded polling completion queue.
import std/[ioring, threadpool, atomics, assertions, syncio]
const Count = 16384
var finished: int
var seen: array[Count, int]
proc child(index: int) {.passive.} =
  assert isPoolWorker()
  var result = -1
  let continuation = delay()
  discard submitNop(never, continuation, addr result)
  suspend()
  assert result == 0
  assert atomicFetchAdd(seen[index], 1, moAcquireRelease) == 0, "continuation resumes once"
  discard atomicFetchAdd(finished, 1, moRelease)

for i in 0..<Count: submit(delay(child(i)))
let deadline = afterMs(60000)
var completions = default(array[16, IoCompletion])
while atomicLoad(finished, moAcquire) != Count:
  # Saturated submit may run a returned continuation on the main thread.
  # Service its standard lane, as the process runner does.
  discard pollCompletions(completions)
  if monoNow() >= deadline:
    echo "FAIL pressure: completed=", atomicLoad(finished, moAcquire), " expected=", Count, " workers=", workerCount
    assert false, "continuation count mismatch under submission pressure"
shutdown()
for index in 0..<Count: assert atomicLoad(seen[index], moAcquire) == 1
assert atomicLoad(finished, moAcquire) == Count
echo "PASS unchanged std: 16384 continuation completions"
