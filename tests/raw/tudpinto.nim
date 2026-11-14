{.feature: "assumeSync".}
## Raw UDP constructors preserve their output on failure and refuse a live
## owner; batches keep progress and error apart, and a retry of the unsent
## suffix sends no duplicate.
import std/[assertions, syncio]
import zal_net/[rt, errors], zal_net/rt/cancel
import zal_net/raw/[udp, mmsg], zal_net/net/address, zal_net/net/sockaddr

proc main() {.passive.} =
  let baseline = liveCancelTokens()
  var raw = default(UdpSocket)
  raw.timeoutMs = 73
  raw.family = -1
  raw.error = "preserved"
  assert bindUdpInto(addr raw, 0, "127.0.0.1\0suffix") == InvalidInput
  assert not raw.ok and raw.timeoutMs == 73 and raw.family == -1 and raw.error == "preserved"
  let stopped = newCancelToken()
  cancel(stopped)
  assert connectUdpInto(addr raw, "127.0.0.1", 1234, tok=stopped) == ECancelled
  assert connectUdpInto(addr raw, "127.0.0.1", 1234, deadline=afterMs(0)) == IoTimedOut
  assert connectUdpInto(addr raw, "bad\0host", 1234) == InvalidInput
  assert connectUdpInto(addr raw, default(SocketAddress)) == InvalidInput
  assert not raw.ok and raw.timeoutMs == 73 and raw.error == "preserved"
  release(stopped)
  assert bindUdpInto(addr raw, 0, "127.0.0.1", timeoutMs=0) == 0
  let fd = nativeHandle(raw)
  let target = localAddress(raw)
  assert openUdpInto(addr raw) == ResourceBusy
  assert connectUdpInto(addr raw, target) == ResourceBusy
  assert bindUdpInto(addr raw) == ResourceBusy
  assert nativeHandle(raw) == fd and raw.timeoutMs == 0
  var adoptedRaw = openUdp(timeoutMs=81)
  assert adoptedRaw.ok
  let socketFamily = adoptedRaw.family
  var detached = takeNativeHandle(addr adoptedRaw)
  assert not adoptedRaw.ok and detached >= 0
  assert not adoptUdp(addr raw, detached, socketFamily) and detached >= 0
  assert not adoptUdp(addr adoptedRaw, detached, -1) and detached >= 0
  assert adoptUdp(addr adoptedRaw, detached, socketFamily, timeoutMs=92)
  assert detached == -1 and adoptedRaw.ok and adoptedRaw.timeoutMs == 92
  close(adoptedRaw)
  var conflict = default(UdpSocket)
  conflict.error = "bind failure"
  assert bindUdpInto(addr conflict, target.port, "127.0.0.1") < 0
  assert not conflict.ok and conflict.error == "bind failure"

  var sender = openUdp(timeoutMs=0)
  assert sender.ok
  var outgoing = default(MmsgBatch)
  var incoming = default(MmsgBatch)
  assert initBatch(outgoing, 4) and initBatch(incoming, 4)
  # Batch headers keep the IPv4 fallback and mapped dual-stack targets.
  for i in 0..<3: setOutgoing(outgoing, i, i + 1, forFamily(target, sender.family))
  let sent = sendBatch(sender, addr outgoing, 3, afterMs(2000))
  assert sent.sent == 3 and sent.error == 0
  var received = 0
  while received < 3:
    let count = recvBatch(raw, addr incoming, afterMs(2000))
    assert count > 0
    for i in 0..<count:
      assert datagramLen(incoming, i) == received + i + 1
    received += count
  let noPackets = sendBatch(sender, addr outgoing, 0)
  assert noPackets.sent == 0 and noPackets.error == 0
  assert sendBatch(sender, addr outgoing, 5).error == InvalidInput
  assert sendBatch(sender, addr outgoing, 1, first = -1).error == InvalidInput
  assert sendBatch(sender, addr outgoing, 1, first = 4).error == InvalidInput
  assert sendBatch(sender, addr outgoing, high(int), first = 1).error == InvalidInput
  let cancelledSend = newCancelToken()
  cancel(cancelledSend)
  let refused = sendBatch(sender, addr outgoing, 1, tok=cancelledSend)
  assert refused.sent == 0 and refused.error == ECancelled
  release(cancelledSend)
  # A valid first datagram followed by a missing destination forces partial
  # progress on native and fallback sendmmsg implementations.
  setOutgoing(outgoing, 0, 1, forFamily(target, sender.family))
  setOutgoing(outgoing, 1, 1, default(SockAddrBuf))
  outgoing.slots[0].buf[0] = 71
  outgoing.slots[1].buf[0] = 72
  let partial = sendBatch(sender, addr outgoing, 2, afterMs(2000))
  assert partial.sent == 1 and partial.error < 0, "partial progress keeps its error"
  assert recvBatch(raw, addr incoming, afterMs(2000)) == 1
  assert datagramLen(incoming, 0) == 1 and incoming.slots[0].buf[0] == 71
  setOutgoing(outgoing, 1, 1, forFamily(target, sender.family))
  let retried = sendBatch(sender, addr outgoing, 2 - partial.sent, afterMs(2000), first=partial.sent)
  assert retried.sent == 1 and retried.error == 0
  assert recvBatch(raw, addr incoming, afterMs(2000)) == 1
  assert datagramLen(incoming, 0) == 1 and incoming.slots[0].buf[0] == 72
  assert recvBatch(raw, addr incoming, afterMs(20)) == IoTimedOut, "the retry sent no duplicate"
  freeBatch(outgoing)
  freeBatch(incoming)
  close(sender)
  close(raw)
  assert liveCancelTokens() == baseline
  echo "PASS raw UDP constructors keep their output, batch progress and retry"

assert runMain(main())
