{.feature: "assumeSync".}
## Ready sockets must honor deadlines and let other tasks run without EAGAIN.
import std/[assertions, syncio]
import zal_net
import zal_net/rt/sync

var turns = 0
var done: Event
proc observer() {.passive.} =
  inc turns
  setEvent(addr done)

proc main() {.passive.} =
  try:
    let listener = listen(0, "127.0.0.1")
    defer: listener.close()
    let client = connect("127.0.0.1", listener.port)
    defer: client.close()
    let server = listener.accept()
    defer: server.close()
    var bytes = [1'u8]
    client.write(bytes)
    try:
      discard server.read(bytes, deadline=afterMs(-1))
      assert false
    except ErrorCode as error: assert error == TimeoutError
    assert server.read(bytes) == 1
    try:
      client.write(bytes, deadline=afterMs(-1))
      assert false
    except ErrorCode as error: assert error == TimeoutError
    assert trySpawnTask(observer())
    # Each operation is ready: write a byte, read it on the same loop.
    for i in 0 ..< 128:
      client.write(bytes)
      assert server.read(bytes) == 1
    assert wait(addr done, afterMs(1000)) == wrReady
    assert turns == 1
    echo "PASS ready-I/O deadlines and cooperative fairness"
  except ErrorCode as error:
    echo error
    assert false
assert runMain(main())
