## Process shutdown drains standard engine tasks and their readiness waiters.
import std/[assertions, syncio, atomics]
import zal_net/[rt, datagram]
import zal_net/raw/socket
import zal_net/rt/blocking

from std/threadpool import isPoolWorker
var stoppedEngines: int
proc onStop(engine: ptr DatagramEngine) {.nimcall.} =
  assert isPoolWorker(), "engine callbacks execute on the standard pool"
  discard atomicFetchAdd(stoppedEngines, 1, moRelease)
var hooks = EngineHooks(onStop: onStop)
var engines: array[8, nil ptr DatagramEngine]
proc main() {.passive.} =
  for i in 0..<engines.len:
    let engine = newDatagramEngine(maxAssocs=16, hooks=addr hooks)
    assert engine != nil
    engines[i] = engine
    if engine != nil:
      startEngine(engine)
      let socket = tryListenUdp(0, bindAddr="127.0.0.1")
      assert socket.ok
      let message = addListener(engine, i, socket.fd)
      let until = afterMs(2000)
      while not engineMsgDone(message) and monoNow() < until: parkUntil(afterMs(1))
      assert engineMsgDone(message) and message.ok
      releaseEngineMsg(message)
  # No per-engine stop message: the process runner must join the engines and
  # all their pending readiness registrations before returning.
  requestStop()
assert runMain(main())
assert runtimeFinished()
for engine in engines:
  if engine != nil:
    assert engineStopped(engine)
    assert freeEngine(engine)
assert atomicLoad(stoppedEngines, moAcquire) == engines.len
assert liveJobInboxes() == 0
echo "PASS process shutdown drained eight engines and pending registrations"
