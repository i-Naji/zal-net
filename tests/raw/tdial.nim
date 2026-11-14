import std/[assertions, syncio]
import zal_net
import zal_net/engine

proc endpoint(host: string; port: uint16): Endpoint =
  result = default(Endpoint)
  assert parseHost(host, port, result)

proc main() {.passive.} =
  try:
    var listener = listen(0, "127.0.0.1")
    let port = listener.port
    var direct = DirectDialer(noDelay: true, timeoutMs: 2000, device: "", mark: 0)
    let d = dialer(addr direct)

    # An address, then a name.
    let first = dialStream(d, endpoint("127.0.0.1", port), afterMs(2000))
    assert first.fd >= 0 and first.code == 0
    var a = accept(listener, afterMs(2000))
    var mine = initConn(first.fd, afterMs(2000))
    mine.write "ping\n"
    assert a.readLine() == "ping"
    close a
    close mine

    let named = dialStream(d, endpoint("localhost", port), afterMs(2000))
    assert named.fd >= 0 and named.code == 0
    closeFd(named.fd)
    var drained = accept(listener, afterMs(2000))
    close drained

    # Nobody listens: no descriptor, and a reason.
    close listener
    let refused = dialStream(d, endpoint("127.0.0.1", port), afterMs(2000))
    assert refused.fd < 0 and refused.code < 0

    # A cancelled token ends the dial before it connects.
    let stop = newCancelToken()
    cancel stop
    let stopped = dialStream(d, endpoint("127.0.0.1", port), afterMs(2000), stop)
    assert stopped.fd < 0 and stopped.code == ECancelled

    # An interface that does not exist fails the attempt before the SYN.
    when defined(linux) or defined(macosx):
      var bound = DirectDialer(noDelay: true, timeoutMs: 2000, device: "zal-no-such-if0", mark: 0)
      let wrong = dialStream(dialer(addr bound), endpoint("127.0.0.1", port), afterMs(2000))
      assert wrong.fd < 0 and wrong.code < 0
    echo "PASS direct dialer: address, name, refused, cancelled, unknown interface"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
