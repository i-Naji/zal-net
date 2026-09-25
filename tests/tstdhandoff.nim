## A main-lane continuation must not run before its current step suspends.
import std/[assertions, syncio]
import std/[atomics, threadpool]
import zal_net/rt
import zal_net/private/runtime
import zal_net/private/core/waitq
import zal_net/private/sys/sock

var completed: int
proc mainLane(armed: bool) {.passive.} =
  assert not isPoolWorker(), "exercise the process runner's inline path"
  var node = default(WaitNode)
  node.state = nsFired
  node.cont = delay()
  if armed: beArmNode(addr node, never)
  else: beSchedule(node.cont)
  # Force overlap if submission is visible to workers before suspension.
  sleepUs(2000)
  assert atomicLoad(completed, moAcquire) == 0, "continuation resumed before original step suspended"
  suspend()
  discard atomicFetchAdd(completed, 1, moRelease)

initRuntime()
for iteration in 0..<32:
  startConn(mainLane(false))
  startConn(mainLane(true))
assert atomicLoad(completed, moAcquire) == 0
requestStop()
drainRuntime()
assert runtimeFinished() and atomicLoad(completed, moAcquire) == 64
echo "PASS 64 main-lane handoffs resume only after suspension and join"
