## A Listener: an accept that times out, one ended by the listener's token,
## accepted connections that outlive both, and `endConnectionsWith`.
import std/[assertions, syncio]
import zal_net/rt
import zal_net/rt/sync
import zal_net/conn

type Shared = ref object
  entered, done: Event
  outcome: ErrorCode

proc parkedAccept(listener: ptr Listener; shared: Shared) {.passive.} =
  setEvent(addr shared.entered)
  try:
    var c = accept(listener[], afterMs(5000))
    close c
    shared.outcome = Success
  except ErrorCode as error:
    shared.outcome = error
  setEvent(addr shared.done)

proc parkedRead(c: ptr Conn; shared: Shared) {.passive.} =
  var bytes = default(array[4, byte])
  setEvent(addr shared.entered)
  try:
    discard c[].read(bytes, afterMs(5000))
    shared.outcome = Success
  except ErrorCode as error:
    shared.outcome = error
  setEvent(addr shared.done)

proc exchange(a, b: var Conn) {.passive, raises.} =
  a.write "ping\n"
  assert b.readLine(afterMs(2000)) == "ping"

proc main() {.passive.} =
  try:
    let tokens = liveCancelTokens()
    var bad = false
    try:
      var refused = listen(0, "127.0.0.1", backlog = 0)
      close refused
    except ErrorCode as error: bad = error == ValueError
    assert bad, "a backlog of 0 is refused"

    block:
      let stop = newCancelToken()
      let drain = newCancelToken()
      var listener = listen(0, "127.0.0.1", stop = stop)
      listener.endConnectionsWith(drain)
      var timedOut = false
      try: discard accept(listener, afterMs(0))
      except ErrorCode as error: timedOut = error == TimeoutError
      assert timedOut

      var first = connect("127.0.0.1", listener.port, afterMs(2000))
      var firstPeer = accept(listener, afterMs(2000))
      var second = connect("127.0.0.1", listener.port, afterMs(2000))
      var secondPeer = accept(listener, afterMs(2000))

      # The listener's token ends a parked accept and nothing else.
      let accepting = Shared(outcome: Success)
      assert trySpawnTask(parkedAccept(addr listener, accepting))
      assert wait(addr accepting.entered, afterMs(2000)) == wrReady
      parkUntil(afterMs(30))
      cancel(stop)
      assert wait(addr accepting.done, afterMs(2000)) == wrReady
      assert accepting.outcome == AbortedOperation
      exchange(first, firstPeer)
      exchange(secondPeer, second)

      # Closing the listener leaves the accepted connections with their owners.
      close listener
      exchange(firstPeer, first)

      # The drain token ends every connection the listener accepted.
      let reading = Shared(outcome: Success)
      assert trySpawnTask(parkedRead(addr secondPeer, reading))
      assert wait(addr reading.entered, afterMs(2000)) == wrReady
      parkUntil(afterMs(30))
      cancel(drain)
      assert wait(addr reading.done, afterMs(2000)) == wrReady
      assert reading.outcome == AbortedOperation
      var bytes = default(array[4, byte])
      assert second.read(bytes, afterMs(2000)) == 0
      assert first.read(bytes, afterMs(2000)) == 0
      assert not cancelled(first.cancelToken), "the client side keeps its own token"

      close first
      close firstPeer
      close second
      close secondPeer
      release(stop)
      release(drain)
    assert liveCancelTokens() == tokens
    echo "PASS accept timeout, a cancelled accept, connections outliving the listener, the drain token"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
