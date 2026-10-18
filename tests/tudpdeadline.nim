{.feature: "assumeSync".}
import std/[assertions, syncio]
import zal_net/[rt, errors]
import zal_net/rt/sync
import zal_net/foundation/udp
import zal_net/raw/mmsg
import zal_net/net/address

var observerDone: Event
proc observer() {.passive.} = setEvent(addr observerDone)

proc exercise(receiver, sender, unconnected: UdpSocketRef) {.passive.} =
  let target = localAddress(receiver)
  let peer = localAddress(sender)
  let expired = afterMs(-1)
  var buffer = [99'u8, 98, 97]
  var empty = default(array[0, byte])
  var source = default(SocketAddress)
  var info = default(DatagramInfo)
  info.ttl = 771
  assert send(sender, [1'u8], expired) == IoTimedOut
  assert send(sender, empty, expired) == IoTimedOut
  assert sendTo(unconnected, [2'u8], target, expired) == IoTimedOut
  assert sendWithSource(unconnected, [3'u8], target, loopback4(), deadline=expired) == IoTimedOut
  # None of the expired sends may leave a packet behind.
  assert recvFrom(receiver, buffer, source, afterMs(20)) == IoTimedOut
  assert send(sender, [42'u8], afterMs(2000)) == 1
  assert recvFrom(receiver, buffer, source, expired) == IoTimedOut
  assert recvFrom(receiver, empty, source, expired) == IoTimedOut
  assert recvFrom(receiver, buffer, info, expired) == IoTimedOut
  assert buffer[0] == 99 and source.port == 0 and info.ttl == 771
  assert recvFrom(receiver, buffer, source, afterMs(2000)) == 1
  assert buffer[0] == 42
  assert sendTo(receiver, [43'u8], peer, afterMs(2000)) == 1
  assert recv(sender, buffer, expired) == IoTimedOut
  assert recv(sender, empty, expired) == IoTimedOut
  assert recv(sender, buffer, afterMs(2000)) == 1 and buffer[0] == 43

  var outgoing, incoming = default(MmsgBatch)
  assert initBatch(outgoing, 2) and initBatch(incoming, 2)
  defer:
    freeBatch(outgoing)
    freeBatch(incoming)
  outgoing.slots[0].buf[0] = 44
  setOutgoing(outgoing, 0, 1, target.raw)
  assert sendBatch(unconnected, outgoing, 1, expired).error == IoTimedOut
  assert recvFrom(receiver, buffer, source, afterMs(20)) == IoTimedOut
  let sent = sendBatch(unconnected, outgoing, 1, afterMs(2000))
  assert sent.sent == 1 and sent.error == 0
  assert recvBatch(receiver, incoming, expired) == IoTimedOut
  assert recvBatch(receiver, incoming, afterMs(2000)) == 1
  assert datagramLen(incoming, 0) == 1 and incoming.slots[0].buf[0] == 44
  # A zero-entry batch does no I/O; an empty datagram still does.
  let noPackets = sendBatch(unconnected, outgoing, 0, expired)
  assert noPackets.sent == 0 and noPackets.error == 0

  assert trySpawnTask(observer())
  for i in 0..<1024:
    assert send(sender, [45'u8], afterMs(2000)) == 1
    assert recvFrom(receiver, buffer, source, afterMs(2000)) == 1
  assert isSet(addr observerDone), "ready UDP traffic lets another task run"

proc main() {.passive.} =
  let r = bindUdpRef(0, "127.0.0.1")
  let receiver = r.value
  assert receiver != nil
  if receiver != nil:
    defer: discard close(receiver)
    let s = connectUdpRef(localAddress(receiver))
    let u = bindUdpRef(0, "127.0.0.1")
    let sender = s.value
    let unconnected = u.value
    assert sender != nil and unconnected != nil
    if sender != nil and unconnected != nil:
      defer:
        discard close(sender)
        discard close(unconnected)
      exercise(receiver, sender, unconnected)
  echo "PASS UDP deadlines preserve queued packets and ready-I/O fairness"

assert runMain(main())
