## Runtime shutdown cancels every kind of parked operation, including an
## infinite in-memory wait, joins workers and permits harmless repeated stop.
import std/[atomics, assertions, syncio]
import zal_net/rt, zal_net/raw/io, zal_net/rt/sync
import zal_net/raw/tcp, zal_net/net/address
import zal_net/net/stream as streams
import zal_net/relay/conn
import zal_net/rt/task, zal_net/errors

var gate: Event
var entered, done: int
proc waiter() {.passive.} =
  discard atomicFetchAdd(entered, 1, moRelease)
  assert wait(addr gate, never) == wrClosed
  discard atomicFetchAdd(done, 1, moRelease)
proc sleeper() {.passive.} =
  discard atomicFetchAdd(entered, 1, moRelease)
  parkUntil(afterMs(60_000))
  assert stopping()
  discard atomicFetchAdd(done, 1, moRelease)
proc reader(s: TcpStreamPtr) {.passive.} =
  var data = default(array[16, byte])
  discard atomicFetchAdd(entered, 1, moRelease)
  assert recvInto(s, addr data[0], data.len, never) == ECancelled
  close(s)
  discard atomicFetchAdd(done, 1, moRelease)
proc relayWait(a, b: TcpStreamPtr) {.passive.} =
  discard atomicFetchAdd(entered, 1, moRelease)
  let stats = streams.relay(a, b, idleMs = 0, splice = false)
  assert stats.aToB.error < 0 and stats.bToA.error < 0
  close(a)
  close(b)
  discard atomicFetchAdd(done, 1, moRelease)
proc rejectedBody(t: Task; arg: nil pointer): int {.passive.} =
  assert false
  result = 0
proc main() {.passive.} =
  var listener = listenTcp(0, "127.0.0.1")
  var client = connect("127.0.0.1", port(listener), streamTimeoutMs = 0)
  var server = accept(listener, streamTimeoutMs = 0)
  var relayClient = connect("127.0.0.1", port(listener), streamTimeoutMs = 0)
  var relayServer = accept(listener, streamTimeoutMs = 0)
  closeNow(listener)
  spawnTask relayWait(addr relayClient, addr relayServer)
  spawnTask waiter()
  spawnTask sleeper()
  spawnTask reader(addr server)
  while atomicLoad(entered, moAcquire) < 1 + 3:
    parkUntil(afterMs(1))
  requestStop()
  while atomicLoad(done, moAcquire) < 1 + 3: yieldNow()
  assert not tryStartConn(sleeper())
  assert not trySpawnTask(sleeper())
  let rejected = startTask(rejectedBody, nil)
  assert finished(rejected) and cancelled(rejected)
  assert code(rejected) == ResourceClosed
  release(rejected)
  let stoppedRelay = streams.relay(addr relayClient, addr relayServer)
  assert stoppedRelay.aToB.error == ECancelled
  let c = newConn(1000)
  assert c != nil
  startPumps(c) # the second pump is rejected; no leaked connection reference
  assert liveConnections() == 0
  assert stopRelayPool()
  close(addr client)
initRuntime()
spawnTask main()
drainRuntime()
assert runtimeFinished()
assert atomicLoad(done, moAcquire) == 1 + 3
requestStop()
drainRuntime() # no restart
echo "PASS runtime cancelled waits, drained I/O, joined workers and released pollers"
