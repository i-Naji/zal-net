## Shutdown drains queued work and retains workers held in a blocking OS call.
import std/[atomics, assertions, syncio]
import zal_net/rt/blocking
import zal_net/private/sys/sock

var entered, proceed, completed: int
proc held(j: JobPtr) {.nimcall.} =
  atomicStore(entered, 1, moRelease)
  while atomicLoad(proceed, moAcquire) == 0: sleepUs(1000)
  discard atomicFetchAdd(completed, 1, moRelease)
proc queued(j: JobPtr) {.nimcall.} =
  discard atomicFetchAdd(completed, 1, moRelease)

initBlockingPool(threads = 1, maxQueued = 1)
let a = newJob(sizeof(Job), held)
assert spawnBlocking(a)
releaseJob(a)
while atomicLoad(entered, moAcquire) == 0: sleepUs(1000)
let b = newJob(sizeof(Job), queued)
assert spawnBlocking(b)
releaseJob(b)
let rejected = newJob(sizeof(Job), queued)
assert not spawnBlocking(rejected) # queue bound
stopBlockingPool()
assert not spawnBlocking(rejected) # closing
assert not joinBlockingPool() # held worker still owns its memory
releaseJob(rejected)
atomicStore(proceed, 1, moRelease)
var waited = 0
while not blockingPoolStopped() and waited < 5000:
  sleepUs(1000)
  waited = waited + 1
assert blockingPoolStopped()
assert joinBlockingPool()
assert joinBlockingPool()
stopBlockingPool()
let after = newJob(sizeof(Job), queued)
assert not spawnBlocking(after)
releaseJob(after)
assert atomicLoad(completed, moAcquire) == 2
assert liveBlockingJobs() == 0
echo "PASS blocking pool bounded queue, drain, join, repeated stop, no restart"
