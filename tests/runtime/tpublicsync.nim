{.feature: "assumeSync".}
## Invalid channel dimensions, nested plain values and token release/cancel.
import std/[atomics, assertions, syncio]
import zal_net/rt/sync, zal_net/plain
import zal_net/private/sys/threads
import zal_net/private/core/waitq

type
  Plain = object
    tag: int
    nested: tuple[x: array[3, uint64], p: nil pointer]
  Bad = object
    nested: tuple[x: int, text: string]
  DistinctInt = distinct int

let channel = newChannel[Plain](2)
let distincts = newPromise[DistinctInt]()
release(channel)
release(distincts)
release(distincts)
assert newChan(0, 1) == nil
assert newChan(-1, 1) == nil
assert newChan(1, 0) == nil
assert newChan(1, -1) == nil
assert newChan(high(int), 2) == nil
assert not validChanSize(2, high(int))
assert validChanSize(1, high(int))
var absent: nil Chan = nil
close(absent)
release(absent)
var item = 1
assert not trySend(absent, addr item)
assert not tryRecv(absent, addr item)

# Force cancellation to win just before readiness claims a stored permit.
# Notify uses this same primitive during its locked readiness recheck.
var waiter = default(WaitNode)
waiter.state = nsParked
var permits = 1
proc take(): bool =
  permits = permits - 1
  result = true
assert tryClaim(addr waiter, wrCancelled)
assert not claimReady(addr waiter, take())
assert permits == 1 and waiter.res == ord(wrCancelled)
waiter.state = nsParked
assert claimReady(addr waiter, take())
assert permits == 0 and waiter.res == ord(wrReady)

# Concurrent final child release and parent cancellation. The parent list
# must never allow a reference count of zero to be retained again.
const Cycles = 20_000
let baseline = liveCancelTokens()
var parent: nil CancelToken = nil
var child: nil CancelToken = nil
var phase, released: int
proc releaser(arg: nil pointer) {.nimcall.} =
  var i = 1
  while i <= Cycles:
    while atomicLoad(phase, moAcquire) != i: cpuRelax()
    release(child)
    atomicStore(released, i, moRelease)
    i = i + 1

var thread: ThreadHandle
assert startJoinable(thread, releaser, nil)
var i = 1
while i <= Cycles:
  parent = newCancelToken()
  child = newCancelToken(parent)
  atomicStore(phase, i, moRelease)
  cancel(parent)
  while atomicLoad(released, moAcquire) != i: cpuRelax()
  release(parent)
  i = i + 1
assert joinThread(thread)
assert liveCancelTokens() == baseline
echo "PASS channel dimensions/plain data and 20000 parent cancel/final release races"
