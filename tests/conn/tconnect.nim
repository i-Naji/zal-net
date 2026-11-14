## Connecting that fails: a refused port, an expired deadline, a cancelled
## token, bad names and addresses, a Unix path nobody listens on. No failure
## leaks a token.
import std/[assertions, syncio]
import zal_net/rt
import zal_net/conn
import zal_net/rt/cancel
import zal_net/net/address
from zal_net/private/os import getPid

template raisesWith(expected: ErrorCode; body: untyped) =
  block:
    var got = Success
    try:
      body
    except ErrorCode as error:
      got = error
    assert got == expected, "expected " & $expected & ", got " & $got

proc main() {.passive.} =
  try:
    let tokens = liveCancelTokens()
    var closed = listen(0, "127.0.0.1")
    let refusedPort = closed.port
    close closed
    for cycle in 0 ..< 32:
      raisesWith(RefusedConnection):
        discard connect("127.0.0.1", refusedPort, afterMs(5000))
      raisesWith(RefusedConnection):
        discard connect(initSocketAddress(loopback4(), refusedPort), afterMs(5000))

    var listener = listen(0, "127.0.0.1")
    raisesWith(TimeoutError):
      discard connect("127.0.0.1", listener.port, afterMs(0))
    let stopped = newCancelToken()
    cancel(stopped)
    raisesWith(AbortedOperation):
      discard connect("127.0.0.1", listener.port, afterMs(2000), stop = stopped)
    release(stopped)
    raisesWith(ValueError):
      discard connect(default(SocketAddress), afterMs(2000))
    raisesWith(ValueError):
      discard connect("127.0.0.1\0ignored", listener.port, afterMs(2000))
    block:
      var c = connect("localhost", listener.port, afterMs(2000))
      var peer = accept(listener, afterMs(2000))
      c.write "ok"
      var buffer = default(array[2, byte])
      var got = 0
      while got < 2: got += peer.read(buffer.toOpenArray(got, 1), afterMs(2000))
    close listener

    when not defined(windows):
      let path = "/tmp/zal-connect-" & $getPid() & ".sock"
      var local = listenUnix(path)
      close local
      for cycle in 0 ..< 32:
        var failed = false
        try: discard connectUnix(path, afterMs(2000))
        except ErrorCode: failed = true
        assert failed, "no listener at the path"
      raisesWith(ValueError):
        discard connectUnix("", afterMs(2000))
      raisesWith(ValueError):
        discard connectUnix(path & "\0suffix", afterMs(2000))

    # A failed connect can drop its last token reference on another worker
    # a moment after it raised.
    let drainedBy = afterMs(2000)
    while liveCancelTokens() != tokens and monoNow() < drainedBy: parkUntil(afterMs(1))
    assert liveCancelTokens() == tokens, "failed connects released their tokens"
    echo "PASS refused, expired, cancelled and malformed connects raise and leak nothing"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
