## Scoped close runs on return, including nested passive forwarding templates.
import std/[assertions, syncio, envvars]
import zal_net/[rt, errors]
import zal_net/foundation/tcp, zal_net/foundation/tcplistener, zal_net/foundation/udp, zal_net/foundation/unix, zal_net/net/scoped, zal_net/raw/unix
import zal_net/private/sys/sock

proc earlyTcp(conn: TcpConnRef) {.passive.} =
  withTcp(conn):
    yieldNow()
    return
proc earlyUnix(conn: UnixConnRef) {.passive.} =
  withUnix(conn):
    yieldNow()
    return

proc main() {.passive.} =
  let opened = listenTcpRef(0, "127.0.0.1")
  let listener = opened.value
  if listener == nil: assert false
  else:
    withListener(listener):
      let connected = connectTcpConn("127.0.0.1", port(listener), deadline=afterMs(5000))
      let accepted = acceptConn(listener, deadline=afterMs(5000))
      let client = connected.value
      let server = accepted.value
      if client == nil or server == nil: assert false
      else:
        earlyTcp(client)
        assert state(client) == ownerClosed
        assert close(server) == 0
    assert state(listener) == ownerClosed
  let bound = bindUdpRef(0, "127.0.0.1")
  let socket = bound.value
  if socket == nil: assert false
  else:
    withUdp(socket): yieldNow()
    assert state(socket) == ownerClosed
  when defined(windows):
    let path = getEnv("TEMP") & "\\nn-scoped-" & $getPid() & ".sock"
  else:
    let path = "/tmp/nn-scoped-" & $getPid() & ".sock"
  var rawListener = listenUnix(path)
  assert rawListener.ok
  let connectedUnix = connectUnixConn(path, deadline=afterMs(5000))
  var peer = accept(rawListener, deadline=afterMs(5000))
  assert peer.isOpen
  let unix = connectedUnix.value
  if unix == nil: assert false
  else:
    earlyUnix(unix)
    assert state(unix) == ownerClosed
  close(addr peer)
  closeNow(rawListener)
  echo "PASS scoped TCP, UDP, listener and Unix return cleanup"

assert runMain(main())
