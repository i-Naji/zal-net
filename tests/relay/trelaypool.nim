## Atomic admission, typed storage, and draining pooled mapped blocks.
import std/[assertions, atomics, syncio]
import zal_net/relay/conn
import zal_net/private/sys/[threads, sock]

type UserState = object
  value: uint64
var ready, proceed, successes: int
proc reserve(arg: nil pointer) {.nimcall.} =
  let c = newConn(1000, maxConns = 1)
  if c != nil: discard atomicFetchAdd(successes, 1, moRelaxed)
  discard atomicFetchAdd(ready, 1, moRelease)
  while atomicLoad(proceed, moAcquire) == 0: sleepUs(1000)
  if c != nil: freeConn(c)

var workers: array[8, ThreadHandle]
for i in 0 ..< workers.len: assert startJoinable(workers[i], reserve, nil)
while atomicLoad(ready, moAcquire) < workers.len: sleepUs(1000)
assert atomicLoad(successes, moAcquire) == 1
assert liveConnections() == 1
atomicStore(proceed, 1, moRelease)
for i in 0 ..< workers.len: assert joinThread(workers[i])
assert liveConnections() == 0
let c = newConn(1000)
assert c != nil
let state = extensionState[UserState](c)
assert state.value == 0
state.value = 42
assert extensionState[UserState](c).value == 42
assert sourceState[byte](addr c.a)[] == 0
freeConn(c)
let held = newConn(1000)
assert held != nil
assert extensionState[UserState](held).value == 0
assert not stopRelayPool()
assert newConn(1000) == nil
freeConn(held)
assert stopRelayPool()
assert stopRelayPool()
assert liveConnections() == 0
assert liveAltBlocks() == 0
echo "PASS relay admission, typed storage, pool drain and repeated shutdown"
