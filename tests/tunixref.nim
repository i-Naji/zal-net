{.feature: "assumeSync".}
## Stable Unix owners: cancelled operations preserve usability; closing drains.
import std/[assertions, syncio, envvars]
import zal_net/[rt, errors], zal_net/rt/[sync, cancel]
import zal_net/raw/unix, zal_net/foundation/unix
import zal_net/private/sys/sock

var entered = default(Event)
var finished = default(Event)
var readCode = 0

proc readPending(conn: sink UnixConnRef) {.passive.} =
  var bytes = default(array[8, byte])
  setEvent(addr entered)
  readCode = recvInto(conn, bytes, afterMs(2000))
  setEvent(addr finished)

proc readCancelled(conn: sink UnixConnRef; tok: CancelToken) {.passive.} =
  # The parent retains tok until finished; the raw operation retains its wait.
  var bytes = default(array[8, byte])
  setEvent(addr entered)
  readCode = recvInto(conn, bytes, afterMs(2000), tok)
  setEvent(addr finished)

proc main() {.passive.} =
  when defined(windows):
    let path = getEnv("TEMP") & "\\nn-unixref-" & $getPid() & ".sock"
  else:
    let path = "/tmp/nn-unixref-" & $getPid() & ".sock"
  var listener = listenUnix(path)
  assert listener.ok, listener.error
  var raw = connectUnix(path)
  assert raw.isOpen
  var peer = accept(listener, deadline=afterMs(2000))
  assert peer.isOpen
  let adopted = takeUnixConn(raw)
  assert adopted.code == 0 and not raw.isOpen
  let candidate = adopted.value
  if candidate != nil:
    let conn: UnixConnRef = candidate
    assert state(conn) == ownerOpen
    var bytes = [41'u8]
    var empty = default(array[0, byte])
    assert recvInto(conn, empty) == 0 and sendFrom(conn, empty) == 0
    let tok = newCancelToken()
    cancel(tok)
    assert recvInto(conn, bytes, afterMs(2000), tok) == ECancelled
    assert sendFrom(conn, bytes, afterMs(2000), tok) == ECancelled
    release(tok)
    assert state(conn) == ownerOpen
    let pendingToken = newCancelToken()
    assert trySpawnTask(readCancelled(conn, pendingToken))
    assert wait(addr entered, afterMs(2000)) == wrReady
    cancel(pendingToken)
    assert wait(addr finished, afterMs(2000)) == wrReady
    release(pendingToken)
    assert readCode == ECancelled and state(conn) == ownerOpen
    clearEvent(addr entered)
    clearEvent(addr finished)
    assert sendFrom(conn, bytes, afterMs(2000)) == 1
    assert recvInto(addr peer, bytes, afterMs(2000)) == 1 and bytes[0] == 41
    assert sendFrom(addr peer, bytes, afterMs(2000)) == 1
    assert recvInto(conn, bytes, afterMs(2000)) == 1 and bytes[0] == 41
    assert trySpawnTask(readPending(conn))
    assert wait(addr entered, afterMs(2000)) == wrReady
    assert recvInto(conn, bytes) == ResourceBusy, "pending read holds Unix admission"
    let firstClose = close(conn, afterMs(0))
    assert firstClose == 0 or firstClose == IoTimedOut
    assert state(conn) != ownerOpen, "deadline cannot reopen an owner"
    assert sendFrom(conn, bytes) == ResourceClosed
    assert close(conn, afterMs(2000)) == 0, "Unix close drains pending I/O"
    assert wait(addr finished, afterMs(2000)) == wrReady
    assert readCode == ResourceClosed, "closing cancels the Unix reader"
    assert state(conn) == ownerClosed and nativeHandle(conn) == -1
    assert close(conn) == 0
  else:
    assert false, "owner construction"
  close(addr peer)
  for cycle in 0..<32:
    clearEvent(addr entered)
    clearEvent(addr finished)
    var client = connectUnix(path)
    assert client.isOpen
    var remote = accept(listener, deadline=afterMs(2000))
    assert remote.isOpen
    block:
      let wrapped = takeUnixConn(addr client)
      let captured = wrapped.value
      if captured != nil:
        assert trySpawnTask(readPending(captured))
      else:
        assert false, "owner transfer"
    assert wait(addr entered, afterMs(2000)) == wrReady
    close(addr remote)
    assert wait(addr finished, afterMs(2000)) == wrReady
    assert readCode == 0, "queued final owner reads EOF"
    yieldNow()
  echo "PASS Unix friendly data, cancellation, direction admission and drained close"
  close(addr peer)
  closeNow(listener)

assert runMain(main())
