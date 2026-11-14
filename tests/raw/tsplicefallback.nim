## Output refusal after successful pipe ingress must preserve every source byte.
import std/[assertions, syncio]
import zal_net/raw

when defined(linux) and defined(nnStreamFaultTest):
  proc rejectOutput() {.importc: "nn_test_reject_splice_output".}
  proc pending(): cint {.importc: "nn_test_splice_rejection_pending".}
  const Total = 16384
  type Sink = object
    count: int
    done: Event
  proc receive(s: TcpStreamPtr; state: ptr Sink) {.passive.} =
    var bytes = default(array[1024, byte])
    while true:
      let n = recvInto(s, bytes, afterMs(2000))
      assert n >= 0
      if n == 0: break
      for i in 0..<n:
        assert bytes[i] == byte((state.count + i) mod 251)
      state.count = state.count + n
    setEvent(addr state.done)
  proc main() {.passive.} =
    var listener = listenTcp(0, "127.0.0.1")
    assert listener.ok
    var input = connect("127.0.0.1", listener.port)
    var source = accept(listener)
    var destination = connect("127.0.0.1", listener.port)
    var output = accept(listener)
    var bytes = default(array[Total, byte])
    for i in 0..<Total: bytes[i] = byte(i mod 251)
    assert writeAll(addr input, bytes)
    shutdownWrite(addr input)
    var state = default(Sink)
    assert trySpawnTask(receive(addr output, addr state))
    rejectOutput()
    let copied = copy(addr source, addr destination, idleMs = 2000)
    shutdownWrite(addr destination)
    assert wait(addr state.done, afterMs(3000)) == wrReady
    assert pending() == 0, "egress fault was not exercised"
    assert copied.error == 0 and copied.bytes == Total, "pipe bytes lost during fallback"
    assert state.count == Total
    close(addr input)
    close(addr source)
    close(addr destination)
    close(addr output)
    closeNow(listener)
    echo "PASS rejected splice output preserves buffered pipe bytes and EOF"
  assert runMain(main())
else:
  echo "SKIP deterministic splice-output fault requires Linux -d:nnStreamFaultTest"
