## Retained managed owners, one waiter per direction, and drain-on-close.
import std/[assertions, syncio]
import zal_net/[rt, errors], zal_net/rt/sync
import zal_net/raw/tcp, zal_net/foundation/tcp, zal_net/net/address

var entered = default(Event)
var finished = default(Event)
var readCode = 0

proc readPending(conn: sink TcpConnRef) {.passive.} =
  var bytes = default(array[8, byte])
  setEvent(addr entered)
  readCode = recvInto(conn, bytes, afterMs(2000))
  setEvent(addr finished)

proc main() {.passive.} =
  var listener = listenTcp(0, "127.0.0.1")
  assert listener.ok, "friendly owner check 24"
  var client = connect("127.0.0.1", port(listener))
  assert client.isOpen, "friendly owner check 26"
  var peer = accept(listener, deadline=afterMs(2000))
  assert peer.isOpen, "friendly owner check 28"
  let adopted = takeTcpConn(client)
  assert adopted.code == 0 and not client.isOpen, "friendly owner check 30"
  let candidate = adopted.value
  if candidate != nil:
    let conn: TcpConnRef = candidate
    assert state(conn) == ownerOpen, "friendly owner check 34"
    assert state(conn) == ownerOpen and nativeHandle(conn) >= 0
    assert trySpawnTask(readPending(conn)), "friendly owner check 35"
    assert wait(addr entered, afterMs(2000)) == wrReady, "friendly owner check 36"
    var bytes = default(array[8, byte])
    assert recvInto(conn, bytes) == ResourceBusy, "friendly owner check 38"
    assert close(conn, afterMs(2000)) == 0, "friendly owner check 39"
    assert wait(addr finished, afterMs(2000)) == wrReady, "friendly owner check 40"
    assert readCode == ResourceClosed, "friendly owner check 41"
    assert state(conn) == ownerClosed and nativeHandle(conn) == -1, "friendly owner check 42"
    assert close(conn) == 0, "friendly owner check 43"
    assert recvInto(conn, bytes) == ResourceClosed, "friendly owner check 44"
    assert sendFrom(conn, bytes) == ResourceClosed, "friendly owner check 45"
  else:
    assert false, "friendly owner check 47"
  close(addr peer)
  # The queued task is the sole owner after this block ends. Its sink
  # capture must survive both queueing and the read park, then clean up.
  for cycle in 0..<64:
    clearEvent(addr entered)
    clearEvent(addr finished)
    var raw = connect("127.0.0.1", port(listener))
    assert raw.isOpen
    var remote = accept(listener, deadline=afterMs(2000))
    assert remote.isOpen
    block:
      let wrapped = takeTcpConn(addr raw)
      let captured = wrapped.value
      if captured != nil:
        assert trySpawnTask(readPending(captured))
      else:
        assert false, "owner construction"
    assert wait(addr entered, afterMs(2000)) == wrReady
    close(addr remote)
    assert wait(addr finished, afterMs(2000)) == wrReady
    assert readCode == 0, "last queued owner reads EOF"
    yieldNow()
  closeNow(listener) # no serve/accept loops were started
  echo "PASS friendly TCP transfer, direction admission and drained close"

assert runMain(main()), "friendly owner check 52"
