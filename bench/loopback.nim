import std/[assertions, syncio, algorithm]
import zal_net
import zal_net/rt/sync

when defined(bulk):
  const Size = 65536
  const Rounds = 512
else:
  const Size = 64
  const Rounds = 5000

type Context = ref object
  done: Event
  error: ErrorCode

proc serve(listener: sink TcpListener; context: sink Context) {.passive.} =
  try:
    let stream = listener.accept(deadline=afterMs(5000))
    defer: stream.close()
    var buffer = newSeq[byte](Size)
    while true:
      let count = stream.read(buffer, deadline=afterMs(5000))
      if count == 0: break
      stream.write(buffer.toOpenArray(0, count - 1), deadline=afterMs(5000))
  except ErrorCode as error:
    context.error = error
  setEvent(addr context.done)

proc main() {.passive.} =
  try:
    let listener = listen(0, "127.0.0.1")
    defer: listener.close()
    let context = Context()
    assert trySpawnTask(serve(listener, context))
    let stream = connect("127.0.0.1", listener.port, deadline=afterMs(5000))
    var payload = newSeq[byte](Size)
    var reply = newSeq[byte](Size)
    for i in 0..<Size: payload[i] = byte(i mod 251)
    var samples = newSeq[int64](Rounds)
    let started = monoNow()
    for round in 0..<Rounds:
      let before = monoNow()
      stream.write(payload, deadline=afterMs(5000))
      var received = 0
      while received < Size:
        let count = stream.read(reply.toOpenArray(received, Size - 1), deadline=afterMs(5000))
        assert count > 0
        received += count
      samples[round] = int64(monoNow()) - int64(before)
      assert reply == payload
    let elapsed = int64(monoNow()) - int64(started)
    stream.close()
    assert wait(addr context.done, afterMs(5000)) == wrReady
    assert context.error == Success
    samples.sort()
    echo "workers=", runtimeWorkers(), " bytes=", Size, " rounds=", Rounds,
      " elapsed_ns=", elapsed, " p50_ns=", samples[Rounds div 2],
      " p99_ns=", samples[(Rounds * 99) div 100]
  except ErrorCode as error:
    echo error
    assert false
assert runMain(main())
