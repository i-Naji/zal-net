{.feature: "assumeSync".}
## A timed-out listing owns its result storage until the engine releases it.
## Internal setup seeds associations without network traffic or DNS timing.
import std/[atomics, assertions, syncio]
include zal_net/datagram/engine

const Sentinel = 0xfeed'u64
var named: int
var reportedNameLength = 4
var owner: int

proc name(a: ptr Assoc; outp: ptr UncheckedArray[char]; capacity: int): int =
  assert capacity >= 4
  outp[0] = 't'
  outp[1] = 'e'
  outp[2] = 's'
  outp[3] = 't'
  discard atomicFetchAdd(named, 1, moRelease)
  result = atomicLoad(reportedNameLength, moAcquire)

proc seed(e: ptr DatagramEngine; m: ptr EngineMsg) =
  for id in 1 .. 3:
    let slot = claimAssoc(e, 0, uint64(id), unixSec())
    assert slot >= 0
    let association = assocAt(e, slot)
    association.owner = addr owner
    association.totUp = int64(id * 10)
  m.ok = true

var hooks = EngineHooks(ownerName: name)

proc waitForJobs(expected: int) {.passive.} =
  let deadline = afterMs(5000)
  while liveBlockingJobs() != expected:
    assert monoNow() < deadline
    sleepMs(1)

proc stopAndFree(e: ptr DatagramEngine) {.passive.} =
  let message = stopEngine(e)
  let deadline = afterMs(5000)
  while not engineMsgDone(message) or not engineStopped(e):
    assert monoNow() < deadline
    sleepMs(1)
  assert message.ok
  releaseEngineMsg(message)
  assert freeEngine(e)

proc main() {.passive.} =
  let jobsBefore = liveBlockingJobs()
  let inboxesBefore = liveJobInboxes()
  var snapshots = @[AssocInfo(id: Sentinel)]

  # A full control queue rejects the listing before any engine thread starts.
  let limited = newDatagramEngine(maxAssocs = 8, controlLimit = 1)
  assert limited != nil
  let queued = newEngineMsg(MsgCall)
  postEngineMsg(limited, queued)
  releaseEngineMsg(queued)
  assert listAssocs(limited, addr snapshots, 8) == -1
  assert snapshots.len == 1 and snapshots[0].id == Sentinel
  assert liveBlockingJobs() == jobsBefore + 1
  assert freeEngine(limited)
  assert liveBlockingJobs() == jobsBefore

  # Destroying an unstarted engine discards a timed-out request and its results.
  let unstarted = newDatagramEngine(maxAssocs = 8)
  assert unstarted != nil
  assert listAssocs(unstarted, addr snapshots, 8) == -1
  assert snapshots.len == 1 and snapshots[0].id == Sentinel
  assert liveBlockingJobs() == jobsBefore + 1
  assert freeEngine(unstarted)
  assert liveBlockingJobs() == jobsBefore

  # A queued seed runs before the late listing; ownerName proves the engine
  # writes real result data after its caller has already returned.
  let engine = newDatagramEngine(maxAssocs = 8, hooks = addr hooks)
  assert engine != nil
  let setup = newEngineMsg(MsgCall)
  setup.call = seed
  postEngineMsg(engine, setup)
  releaseEngineMsg(setup)
  assert listAssocs(engine, addr snapshots, high(int)) == -1
  assert snapshots.len == 1 and snapshots[0].id == Sentinel
  assert liveBlockingJobs() == jobsBefore + 2
  startEngine(engine)
  waitForJobs(jobsBefore)
  assert atomicLoad(named, moAcquire) == 3
  assert snapshots.len == 1 and snapshots[0].id == Sentinel

  assert listAssocs(engine, addr snapshots, 1) == 3
  assert snapshots.len == 2 and snapshots[0].id == Sentinel
  assert snapshots[1].userLen == 4 and snapshots[1].user[0] == 't'
  assert snapshots[1].up > 0
  # Huge caller limits are bounded by the engine's configured association limit.
  assert listAssocs(engine, addr snapshots, high(int)) == 3
  assert snapshots.len == 5
  for i in 2 ..< snapshots.len:
    assert snapshots[i].userLen == 4 and snapshots[i].user[3] == 't'

  atomicStore(reportedNameLength, -1, moRelease)
  assert listAssocs(engine, addr snapshots, 1) == 3
  assert snapshots[5].userLen == 0
  atomicStore(reportedNameLength, MaxOwnerName + 1, moRelease)
  assert listAssocs(engine, addr snapshots, 1) == 3
  assert snapshots[6].userLen == 0
  assert listAssocs(engine, addr snapshots, 0) == -1
  assert snapshots.len == 7
  stopAndFree(engine)
  waitForJobs(jobsBefore)

  let stopped = newDatagramEngine(maxAssocs = 8)
  assert stopped != nil
  startEngine(stopped)
  let stop = stopEngine(stopped)
  let deadline = afterMs(5000)
  while not engineStopped(stopped):
    assert monoNow() < deadline
    sleepMs(1)
  assert engineMsgDone(stop) and stop.ok
  releaseEngineMsg(stop)
  assert listAssocs(stopped, addr snapshots, 8) == -1
  assert snapshots.len == 7
  assert freeEngine(stopped)
  waitForJobs(jobsBefore)
  assert liveJobInboxes() == inboxesBefore
  echo "PASS listing timeout, late result, queue rejection, shutdown, limits and name bounds"
  requestStop()

initRuntime()
spawnTask main()
drainRuntime()
