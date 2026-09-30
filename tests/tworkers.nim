import std/[assertions, atomics, syncio, threadpool]
import zal_net/rt
import zal_net/rt/sync

var done: Event
var completed: int
proc child() {.passive.} =
  assert isPoolWorker()
  discard atomicFetchAdd(completed, 1, moRelease)
  setEvent(addr done)
proc main() {.passive.} =
  let expected = workersFromEnv("ZAL_WORKERS")
  assert expected > 0 and runtimeWorkers() == expected
  assert trySpawnTask(child())
  assert wait(addr done, afterMs(2000)) == wrReady
assert runMain(main())
assert atomicLoad(completed, moAcquire) == 1
assert runtimeFinished()
echo "PASS configured workers: ", runtimeWorkers()
