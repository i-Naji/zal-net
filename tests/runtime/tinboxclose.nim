## Closing a consumer with jobs still running must not leak or use its wrapper.
import std/[atomics, assertions, syncio]
import zal_net/rt, zal_net/rt/blocking, zal_net/raw/io
import zal_net/private/sys/sock

var entered, proceed, disposed, dropped: int
proc runHeld(j: JobPtr) {.nimcall.} =
  discard atomicFetchAdd(entered, 1, moRelease)
  while atomicLoad(proceed, moAcquire) == 0: sleepUs(1000)
proc dispose(j: JobPtr) {.nimcall.} =
  discard atomicFetchAdd(disposed, 1, moRelease)
proc drop(j: JobPtr) {.nimcall.} =
  discard atomicFetchAdd(dropped, 1, moRelease)
proc noop(j: JobPtr) {.nimcall.} = discard

proc main() {.passive.} =
  let initialJobs = liveBlockingJobs()
  let initialInboxes = liveJobInboxes()
  var inbox = default(JobInbox)
  assert initJobInbox(inbox)
  let delayed = newJob(sizeof(Job), runHeld, dispose, drop)
  assert spawnBlocking(delayed, addr inbox)
  releaseJob(delayed)
  while atomicLoad(entered, moAcquire) == 0: parkUntil(afterMs(1))
  let queued = newJob(sizeof(Job), noop, dispose, drop)
  assert postJob(addr inbox, queued)
  releaseJob(queued)
  closeJobInbox(inbox)
  closeJobInbox(inbox)
  assert inboxFd(inbox) == -1
  assert atomicLoad(disposed, moAcquire) == 1
  assert atomicLoad(dropped, moAcquire) == 1
  assert liveJobInboxes() == initialInboxes + 1 # running producer still owns it
  let rejected = newJob(sizeof(Job), noop, dispose)
  assert not spawnBlocking(rejected, addr inbox)
  assert not postJob(addr inbox, rejected)
  releaseJob(rejected)
  atomicStore(proceed, 1, moRelease)
  let deadline = afterMs(5000)
  while liveBlockingJobs() != initialJobs or liveJobInboxes() != initialInboxes:
    assert monoNow() < deadline
    parkUntil(afterMs(1))
  assert atomicLoad(disposed, moAcquire) == 3
  assert atomicLoad(dropped, moAcquire) == 2
  echo "PASS inbox close: queued, running, late delivery, repeated close and rejection"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
