{.feature: "assumeSync".}
## Typed task arguments, retained slots, immutable copies and offload cleanup.
import std/[assertions, syncio]
import std/atomics
import zal_net/[rt, errors], zal_net/rt/[sync, cancel, task, blocking]
import zal_net/net/concurrency

proc compute(tok: CancelToken; argument: int): int {.nimcall, passive.} =
  yieldNow()
  result = argument * 3

proc sleepy(tok: CancelToken; argument: int): int {.nimcall, passive.} =
  if sleepUntil(afterMs(2000), tok) == wrCancelled: return ECancelled
  result = argument

proc double(argument: int): int {.nimcall.} = argument * 2

type PublishArgument = object
  producer: SlotProducer[int]       ## borrowed through this awaited call only
  value: int
proc publishValue(argument: PublishArgument): bool {.nimcall.} =
  fulfil(argument.producer, argument.value)

var publications, completed: int
var publishersDone: Event
proc publisher(slot: sink Slot[int]; value: int) {.passive.} =
  var sender = producer(slot)
  let outcome = offload(publishValue, PublishArgument(producer: sender, value: value))
  assert outcome.code == 0
  release(sender)
  if outcome.value: discard atomicFetchAdd(publications, 1, moRelaxed)
  if atomicFetchAdd(completed, 1, moAcquireRelease) == 15: setEvent(addr publishersDone)

when defined(windows):
  proc nativeSleep(ms: uint32) {.importc: "Sleep", header: "<windows.h>".}
else:
  proc nativeUsleep(us: cuint): cint {.importc: "usleep", header: "<unistd.h>".}

var blockingEntered, abandonedDone: Event
var abandonedCode = 0
proc delayed(argument: int): int {.nimcall.} =
  setEvent(addr blockingEntered)
  when defined(windows): nativeSleep(uint32(argument))
  else: discard nativeUsleep(cuint(argument * 1000))
  result = argument

proc abandoning(tok: CancelToken) {.passive.} =
  let outcome = offload(delayed, 250, tok=tok)
  abandonedCode = outcome.code
  setEvent(addr abandonedDone)

var entered, done: Event
var receivedCode = wrReady
proc waiting(slot: sink Slot[int]) {.passive.} =
  setEvent(addr entered)
  receivedCode = wait(slot, afterMs(2000)).res
  setEvent(addr done)

proc exercise() {.passive.} =
  let empty = Slot[int]()
  close(empty)
  assert not fulfil(empty, 1)
  assert wait(empty).res == wrClosed
  let slot = newSlot[int]()
  var sender = producer(slot)
  var transferred = takeProducer(sender)
  assert not fulfil(sender, 1), "moved producer rejected"
  assert fulfil(transferred, 7)
  assert not fulfil(transferred, 9), "repeat publisher rejected"
  let received = wait(slot, afterMs(2000))
  assert received.res == wrReady and received.value == 7, "committed value cannot be overwritten"
  release(transferred)
  release(transferred)
  let closed = newSlot[int]()
  spawnTask(waiting(closed))
  assert wait(addr entered, afterMs(2000)) == wrReady
  close(closed)
  assert wait(addr done, afterMs(2000)) == wrReady and receivedCode == wrClosed
  assert not fulfil(closed, 42)
  var arrayValue = [1, 2, 3]
  let shared = newShared(arrayValue)
  arrayValue[0] = 9
  var copied = read(shared)
  assert copied[0] == 1
  copied[0] = 8
  assert read(shared)[0] == 1, "Shared never exposes mutable state"
  let raced = newSlot[int]()
  for i in 0..<16: spawnTask(publisher(raced, i))
  assert wait(addr publishersDone, afterMs(5000)) == wrReady
  assert publications == 1, "exactly one concurrent publisher committed"
  let winner = wait(raced, afterMs(2000))
  assert winner.res == wrReady and winner.value >= 0 and winner.value < 16
  let group = newGroup()
  let started = start(group, compute, 9)
  assert started.code == 0
  let handle = started.value
  if handle != nil:
    assert join(handle, afterMs(2000)) == wrReady
    assert finished(handle) and code(handle) == 27
  else: assert false
  let asleep = start(group, sleepy, 0)
  assert asleep.code == 0
  assert close(group, afterMs(0)) == wrCancelled
  let handle2 = asleep.value
  if handle2 != nil:
    assert finished(handle2) and code(handle2) == ECancelled
  else: assert false
  assert start(group, compute, 0).code == ResourceClosed
  let result = offload(double, 21, afterMs(2000))
  assert result.code == 0 and result.value == 42
  let tok = newCancelToken()
  cancel(tok)
  assert offload(double, 5, tok=tok).code == ECancelled
  release(tok)
  assert offload(double, 5, deadline=afterMs(0)).code == IoTimedOut
  let pendingToken = newCancelToken()
  spawnTask(abandoning(pendingToken))
  assert wait(addr blockingEntered, afterMs(5000)) == wrReady
  cancel(pendingToken)
  assert wait(addr abandonedDone, afterMs(5000)) == wrReady
  assert abandonedCode == ECancelled
  release(pendingToken)

proc main() {.passive.} =
  let baseline = liveCancelTokens()
  exercise()
  stopBlockingPool()
  assert offload(double, 1).code == ResourceClosed
  while not joinBlockingPool(): parkUntil(afterMs(1))
  assert liveBlockingJobs() == 0
  assert liveCancelTokens() == baseline
  echo "PASS Group, Slot, Shared, atomic publication and typed offload"

assert runMain(main())
