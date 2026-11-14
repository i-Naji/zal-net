## Ending a Conn: its token cancelled from another task, its parent token,
## its scope, and a second close.
import std/[assertions, syncio]
import zal_net/rt
import zal_net/rt/sync
import zal_net/conn

type Shared = ref object
  entered, done: Event
  outcome: ErrorCode

proc parkedRead(c: ptr Conn; shared: Shared) {.passive.} =
  var bytes = default(array[4, byte])
  setEvent(addr shared.entered)
  try:
    discard c[].read(bytes, afterMs(5000))
    shared.outcome = Success
  except ErrorCode as error:
    shared.outcome = error
  setEvent(addr shared.done)

proc acceptAndLeave(listener: ptr Listener; shared: Shared) {.passive.} =
  # The accepted Conn goes out of scope at the early return, after a park.
  try:
    var c = accept(listener[], afterMs(2000))
    c.write "bye"
    yieldNow()
    setEvent(addr shared.done)
    return
  except ErrorCode as error:
    shared.outcome = error
    setEvent(addr shared.done)

proc main() {.passive.} =
  try:
    let tokens = liveCancelTokens()
    var listener = listen(0, "127.0.0.1")
    var buffer = default(array[16, byte])

    # Cancelling a connection's token ends its parked read, and the peer sees
    # the end because the socket is shut down.
    block:
      var client = connect("127.0.0.1", listener.port, afterMs(2000))
      var peer = accept(listener, afterMs(2000))
      let shared = Shared(outcome: Success)
      assert trySpawnTask(parkedRead(addr client, shared))
      assert wait(addr shared.entered, afterMs(2000)) == wrReady
      parkUntil(afterMs(30))
      cancel(client.cancelToken)
      assert wait(addr shared.done, afterMs(2000)) == wrReady
      assert shared.outcome == AbortedOperation
      assert peer.read(buffer, afterMs(2000)) == 0, "the peer reads the end"
      var refused = false
      try: client.write "late"
      except ErrorCode: refused = true
      assert refused, "a cancelled connection takes no more writes"

    # A connection's token is a child of the one passed to connect: the
    # parent ends every child, a child leaves the parent and its siblings.
    block:
      let parent = newCancelToken()
      var first = connect("127.0.0.1", listener.port, afterMs(2000), stop = parent)
      var firstPeer = accept(listener, afterMs(2000))
      var second = connect("127.0.0.1", listener.port, afterMs(2000), stop = parent)
      var secondPeer = accept(listener, afterMs(2000))
      cancel(first.cancelToken)
      assert not cancelled(parent) and not cancelled(second.cancelToken)
      assert firstPeer.read(buffer, afterMs(2000)) == 0
      second.write "still"
      assert secondPeer.read(buffer, afterMs(2000)) == 5
      let shared = Shared(outcome: Success)
      assert trySpawnTask(parkedRead(addr second, shared))
      assert wait(addr shared.entered, afterMs(2000)) == wrReady
      parkUntil(afterMs(30))
      cancel(parent)
      assert wait(addr shared.done, afterMs(2000)) == wrReady
      assert shared.outcome == AbortedOperation
      assert secondPeer.read(buffer, afterMs(2000)) == 0
      release(parent)

    # A Conn closes when its scope ends, early return and park included.
    block:
      let shared = Shared(outcome: Success)
      assert trySpawnTask(acceptAndLeave(addr listener, shared))
      var client = connect("127.0.0.1", listener.port, afterMs(2000))
      assert wait(addr shared.done, afterMs(2000)) == wrReady
      assert shared.outcome == Success
      var got = 0
      while got < 3:
        let n = client.read(buffer.toOpenArray(got, 15), afterMs(2000))
        assert n > 0
        got += n
      assert client.read(buffer, afterMs(2000)) == 0, "the scope's end closed the peer"

    # Closing twice is fine, and a closed Conn reports it.
    block:
      var client = connect("127.0.0.1", listener.port, afterMs(2000))
      var peer = accept(listener, afterMs(2000))
      close client
      close client
      assert not client.isOpen and client.nativeHandle == -1
      assert peer.read(buffer, afterMs(2000)) == 0

    close listener
    assert liveCancelTokens() == tokens, "every connection released its token"
    echo "PASS a cancelled token, a parent token, the end of a scope and a second close"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
