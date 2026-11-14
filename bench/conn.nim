import std/[assertions, syncio, algorithm]
import zal_net/rt
import zal_net/rt/sync
import zal_net/conn

when defined(bulk):
  const Size = 65536
  const Rounds = 512
else:
  const Size = 64
  const Rounds = 20000

type Context = ref object
  done: Event
  failed: bool

proc serve(listener: ptr Listener; context: Context) {.passive.} =
  try:
    var c = accept(listener[], afterMs(5000))
    var buffer = newSeq[byte](Size)
    while true:
      let count = c.read(buffer, afterMs(5000))
      if count == 0: break
      c.write(buffer.toOpenArray(0, count - 1), afterMs(5000))
  except ErrorCode:
    context.failed = true
  setEvent(addr context.done)

proc main() {.passive.} =
  try:
    var listener = listen(0, "127.0.0.1")
    let context = Context()
    assert trySpawnTask(serve(addr listener, context))
    var c = connect("127.0.0.1", listener.port, afterMs(5000))
    var payload = newSeq[byte](Size)
    var reply = newSeq[byte](Size)
    for i in 0..<Size: payload[i] = byte(i mod 251)
    var samples = newSeq[int64](Rounds)
    let started = monoNow()
    for round in 0..<Rounds:
      let before = monoNow()
      c.write(payload, afterMs(5000))
      var received = 0
      while received < Size:
        let count = c.read(reply.toOpenArray(received, Size - 1), afterMs(5000))
        assert count > 0
        received += count
      samples[round] = int64(monoNow()) - int64(before)
    let elapsed = int64(monoNow()) - int64(started)
    assert reply == payload
    close c
    assert wait(addr context.done, afterMs(5000)) == wrReady
    assert not context.failed
    close listener
    samples.sort()
    echo "workers=", runtimeWorkers(), " bytes=", Size, " rounds=", Rounds,
      " elapsed_ms=", elapsed div 1_000_000, " p50_ns=", samples[Rounds div 2],
      " p99_ns=", samples[(Rounds * 99) div 100]
  except ErrorCode as error:
    echo error
    assert false
assert runMain(main())
