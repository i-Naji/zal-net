## Independently owned engines; late producers retain only completion state.
import std/[atomics, assertions, syncio]
import zal_net/rt/blocking
# Internal lifecycle test: inject a held producer without exporting the inbox.
include zal_net/datagram/engine
import zal_net/private/sys/sock

var entered, proceed: int
proc held(j: JobPtr) {.nimcall.} =
  atomicStore(entered, 1, moRelease)
  while atomicLoad(proceed, moAcquire) == 0: sleepUs(1000)

proc stopAndFree(e: ptr DatagramEngine) =
  let m = stopEngine(e)
  assert waitEngineMsg(m, 2000)
  releaseEngineMsg(m)
  var waited = 0
  while not engineStopped(e) and waited < 5000:
    sleepUs(1000)
    waited = waited + 1
  assert engineStopped(e)
  assert freeEngine(e)

assert newDatagramEngine(listenerLimit = 0) == nil
assert newDatagramEngine(maxAssocs = 3) == nil
assert newDatagramEngine(pendingBytes = 1) == nil
# A full control queue rejects work without retaining it; stop is still admitted.
let bounded = newDatagramEngine(controlLimit = 1, maxAssocs = 8)
assert bounded != nil
bounded.assocs.setLen(1)
resetAssoc(addr bounded.assocs[0])
# A control connection's native failure must clear its transport leg; the
# library no longer collapses every native error to -1.
let brokenControl = sockSocket(AF_INET, SOCK_STREAM, 0)
assert brokenControl >= 0
bounded.assocs[0].pxCtl = brokenControl
bounded.assocs[0].pxReady = true
ctlReady(bounded, 0)
assert bounded.assocs[0].pxCtl == -1 and not bounded.assocs[0].pxReady
# Would-block leaves the leg intact; peer EOF tears it down.
var controlPair = [-1.cint, -1.cint]
assert sockPair(addr controlPair[0]) == 0
assert sockSetNonblock(controlPair[0], true)
bounded.assocs[0].pxCtl = controlPair[0]
bounded.assocs[0].pxReady = true
ctlReady(bounded, 0)
assert bounded.assocs[0].pxCtl == controlPair[0] and bounded.assocs[0].pxReady
assert sockClose(controlPair[1]) == 0
ctlReady(bounded, 0)
assert bounded.assocs[0].pxCtl == -1 and not bounded.assocs[0].pxReady
echo "PASS control-leg native error, would-block and EOF"
let accepted = newEngineMsg(MsgCall)
postEngineMsg(bounded, accepted)
let rejected = newEngineMsg(MsgCall)
postEngineMsg(bounded, rejected)
assert engineMsgDone(rejected) and not rejected.ok
releaseEngineMsg(rejected)
let stop = stopEngine(bounded)
startEngine(bounded)
assert waitEngineMsg(stop, 2000)
releaseEngineMsg(stop)
releaseEngineMsg(accepted)
while not engineStopped(bounded): sleepUs(1000)
assert freeEngine(bounded)

var cycle = 0
while cycle < 20:
  let madeA = newDatagramEngine(listenerLimit = 1, maxAssocs = 8, pendingBytes = 256)
  let madeB = newDatagramEngine(listenerLimit = 2, maxAssocs = 16, pendingBytes = 512)
  assert madeA != nil and madeB != nil
  let a: ptr DatagramEngine = madeA
  let b: ptr DatagramEngine = madeB
  startEngine(a)
  startEngine(b)
  assert not freeEngine(a)
  atomicStore(entered, 0, moRelease)
  atomicStore(proceed, 0, moRelease)
  let job = newJob(sizeof(Job), held)
  assert spawnBlocking(job, a.inbox)
  releaseJob(job)
  while atomicLoad(entered, moAcquire) == 0: sleepUs(1000)
  stopAndFree(a)
  assert not engineStopped(b)
  assert liveJobInboxes() == 2 # A's held producer plus B's consumer
  atomicStore(proceed, 1, moRelease)
  stopAndFree(b)
  var waited = 0
  while (liveJobInboxes() != 0 or liveBlockingJobs() != 0) and waited < 5000:
    sleepUs(1000)
    waited = waited + 1
  assert liveJobInboxes() == 0 and liveBlockingJobs() == 0
  cycle = cycle + 1
stopBlockingPool()
while not blockingPoolStopped(): sleepUs(1000)
assert joinBlockingPool()
echo "PASS independent engines, limits, late completion after free, 20 create/close cycles"

initRuntime()
requestStop()
drainRuntime()
assert runtimeFinished()
