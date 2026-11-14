import std/[assertions, atomics, syncio]
import zal_net/rt
import zal_net/rt/blocking
import zal_net/private/sys/sock

var completed: int
proc late(job: JobPtr) {.nimcall.} =
  sleepUs(40000)
  atomicStore(completed, 1, moRelease)
proc main() {.passive.} =
  let job = newJob(sizeof(Job), late)
  assert spawnBlocking(job)
  releaseJob(job)
assert runMain(main())
assert atomicLoad(completed, moAcquire) == 1
assert blockingPoolStopped() and joinBlockingPool()
assert liveBlockingJobs() == 0
assert runtimeFinished()
echo "PASS process runner joins late blocking jobs"
