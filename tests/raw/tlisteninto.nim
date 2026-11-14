{.feature: "assumeSync".}
## The raw listener calls conn.nim builds on: exact listen and accept
## outcomes, registry capacity, cancellation, busy and closed owners.
import std/[assertions, syncio]
import zal_net/[rt, errors], zal_net/rt/[sync, cancel], zal_net/raw/io
import zal_net/raw/tcp

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
  var closed = default(TcpListener)
  assert acceptInto(addr output, addr closed) == ResourceClosed
  closeNow(raw)
  closeNow(raw)
  let drainedBy = afterMs(2000)
  while liveCancelTokens() != baseline and monoNow() < drainedBy: parkUntil(afterMs(1))
  assert liveCancelTokens() == baseline, "accept tokens released after completion"
  requestStop()
  assert listenInto(addr raw, 0) == ResourceClosed
  echo "PASS raw listen and accept: exact codes, capacity, cancellation, busy and closed owners"

assert runMain(main())
