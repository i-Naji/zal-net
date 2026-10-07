{.feature: "assumeSync".}
## Exact accept outcomes, retained listener owners and quiescent descriptor close.
import std/[assertions, syncio]
import zal_net/[rt, errors], zal_net/rt/[sync, cancel], zal_net/raw/io
import zal_net/raw/tcp, zal_net/foundation/tcp, zal_net/foundation/tcplistener

var entered = default(Event)
var finished = default(Event)
var acceptCode = 0

proc pending(owner: sink TcpListenerRef; tok: nil CancelToken = nil) {.passive.} =
  setEvent(addr entered)
  let got = acceptConn(owner, deadline=afterMs(2000), tok=tok)
  acceptCode = got.code
  let peer = got.value
  if peer != nil: discard close(peer)
  setEvent(addr finished)

proc cancelLater(tok: CancelToken) {.passive.} =
  parkUntil(afterMs(20))
  cancel(tok)
  release(tok)

proc main() {.passive.} =
  let baseline = liveCancelTokens()
  var raw = default(TcpListener)
  raw.error = "unchanged"
  assert listenInto(addr raw, 0, "127.0.0.1", backlog=0) == InvalidInput
  assert not raw.ok and raw.error == "unchanged"
  assert listenInto(addr raw, 0, "127.0.0.1\0suffix") == InvalidInput
  assert listenInto(addr raw, 0, "127.0.0.1") == 0
  assert raw.ok and raw.error == ""
  let fd = nativeHandle(raw)
  assert listenInto(addr raw, 0) == ResourceBusy and nativeHandle(raw) == fd
  # Capacity rejection releases the unpublished descriptor and preserves output.
  var slots = default(array[MaxListeners - 1, TcpListener])
  for i in 0..<slots.len:
    assert listenInto(addr slots[i], 0, "127.0.0.1") == 0
  var full = default(TcpListener)
  full.error = "capacity rejection"
  assert listenInto(addr full, 0, "127.0.0.1") == QueueFull
  assert not full.ok and full.error == "capacity rejection"
  for i in 0..<slots.len: closeNow(slots[i])
  assert listenInto(addr full, raw.port, "127.0.0.1") < 0
  assert not full.ok and full.error == "capacity rejection"
  var output = default(TcpStream)
  output.timeoutMs = 37
  let cancelledToken = newCancelToken()
  cancel(cancelledToken)
  assert acceptInto(addr output, addr raw, tok=cancelledToken) == ECancelled
  assert not output.isOpen and output.timeoutMs == 37
  assert acceptInto(addr output, addr raw, deadline=afterMs(0)) == IoTimedOut
  assert acceptInto(addr output, addr raw, deadline=afterMs(15)) == IoTimedOut
  let token = newCancelToken()
  retain(token) # the queued canceller owns this reference through publication
  assert trySpawnTask(cancelLater(token))
  assert acceptInto(addr output, addr raw, tok=token) == ECancelled
  assert raw.ok and not output.isOpen
  var client = connect("127.0.0.1", raw.port, deadline=afterMs(2000))
  assert client.isOpen
  assert acceptInto(addr output, addr raw, streamTimeoutMs=71, deadline=afterMs(2000)) == 0
  assert output.isOpen and output.timeoutMs == 71
  let peerFd = nativeHandle(output)
  assert acceptInto(addr output, addr raw) == ResourceBusy and nativeHandle(output) == peerFd
  var bytes = [43'u8]
  assert sendFrom(addr client, bytes, afterMs(2000)) == 1
  assert recvInto(addr output, bytes, afterMs(2000)) == 1 and bytes[0] == 43
  close(addr output)
  close(addr client)
  release(token)
  release(cancelledToken)
  let moved = takeTcpListenerRef(raw)
  assert moved.code == 0 and not raw.ok
  let held = moved.value
  if held != nil:
    assert state(held) == ownerOpen
    assert state(held) == ownerOpen
    let stop = newCancelToken()
    clearEvent(addr entered)
    clearEvent(addr finished)
    assert trySpawnTask(pending(held, stop))
    assert wait(addr entered, afterMs(2000)) == wrReady
    let busy = acceptConn(held)
    assert busy.code == ResourceBusy and busy.value == nil
    cancel(stop)
    assert wait(addr finished, afterMs(2000)) == wrReady
    assert acceptCode == ECancelled and state(held) == ownerOpen
    release(stop)
    var sender = connect("127.0.0.1", held.port, deadline=afterMs(2000))
    let accepted = acceptConn(held, deadline=afterMs(2000))
    assert accepted.code == 0
    let peer = accepted.value
    if peer != nil:
      assert sendFrom(addr sender, bytes, afterMs(2000)) == 1
      assert recvInto(peer, bytes, afterMs(2000)) == 1 and bytes[0] == 43
      assert close(peer) == 0
    else: assert false, "accepted connection owner"
    close(addr sender)
    clearEvent(addr entered)
    clearEvent(addr finished)
    assert trySpawnTask(pending(held))
    assert wait(addr entered, afterMs(2000)) == wrReady
    let closed = close(held, afterMs(0))
    assert closed == 0 or closed == IoTimedOut
    assert state(held) != ownerOpen
    let rejected = acceptConn(held)
    assert rejected.code == ResourceClosed and rejected.value == nil
    assert close(held, afterMs(2000)) == 0
    assert wait(addr finished, afterMs(2000)) == wrReady
    assert acceptCode == ResourceClosed and state(held) == ownerClosed
    assert nativeHandle(held) == -1 and close(held) == 0
    var replacement = listenTcp(0, "127.0.0.1")
    assert replacement.ok
    let replacementFd = nativeHandle(replacement)
    assert close(held) == 0
    assert replacement.ok and nativeHandle(replacement) == replacementFd
    var probe = connect("127.0.0.1", replacement.port, deadline=afterMs(2000))
    assert probe.isOpen
    var received = accept(replacement, deadline=afterMs(2000))
    assert received.isOpen, "repeated close cannot retire a replacement descriptor"
    assert sendFrom(addr probe, bytes, afterMs(2000)) == 1
    assert recvInto(addr received, bytes, afterMs(2000)) == 1
    close(addr probe)
    close(addr received)
    echo "replacement descriptor reused: ", replacementFd == fd
    closeNow(replacement)
  else: assert false, "listener transfer"
  # Last queued reference survives admission/parking; its destructor retires
  # the registry slot. Enough cycles to expose any leaked registry entry.
  for cycle in 0..<80:
    clearEvent(addr entered)
    clearEvent(addr finished)
    var port: uint16 = 0
    block:
      let opened = listenTcpRef(0, "127.0.0.1")
      assert opened.code == 0
      let owner = opened.value
      if owner != nil:
        port = owner.port
        assert trySpawnTask(pending(owner))
      else: assert false, "listener creation"
    assert wait(addr entered, afterMs(2000)) == wrReady
    var sender = connect("127.0.0.1", port, deadline=afterMs(2000))
    assert sender.isOpen
    assert wait(addr finished, afterMs(2000)) == wrReady and acceptCode == 0
    close(addr sender)
    yieldNow()
  echo "PASS listener transfer, admission, caller cancellation, drained close and queued final owner"
  var closed = default(TcpListener)
  assert acceptInto(addr output, addr closed) == ResourceClosed
  closeNow(raw)
  closeNow(raw)
  let drainedBy = afterMs(2000)
  while liveCancelTokens() != baseline and monoNow() < drainedBy: parkUntil(afterMs(1))
  assert liveCancelTokens() == baseline, "accept tokens released after completion"
  requestStop()
  assert listenInto(addr raw, 0) == ResourceClosed

assert runMain(main())
