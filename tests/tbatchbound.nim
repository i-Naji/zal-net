## Receive bounds preserve full slot ownership and each datagram's address.
import std/[assertions, syncio]
import zal_net/[rt, errors], zal_net/raw/io
import zal_net/raw/[udp, mmsg], zal_net/net/address

proc bounded(owner: UdpSocket; batch: var MmsgBatch; maximum: int): int {.passive.} =
  let deadline = afterMs(2000)
  var res = 0
  while true:
    result = recvmmsgBatch(nativeHandle(owner), batch, MSG_DONTWAIT, maximum)
    if result >= 0 or result == InvalidInput: return
    parkPoll(nativeHandle(owner), {evRead}, deadline, res)
    assert res > 0, "bounded batch receive timed out"

proc main() {.passive.} =
  var batch = default(MmsgBatch)
  assert initBatch(batch, 4, recvCtrl=true)
  var receiver = bindUdp(0, "127.0.0.1")
  var sender = bindUdp(0, "127.0.0.1")
  assert receiver.ok and sender.ok
  let destination = localAddress(receiver)
  let source = localAddress(sender)
  assert recvmmsgBatch(nativeHandle(receiver), batch, MSG_DONTWAIT, -1) == InvalidInput
  assert recvmmsgBatch(nativeHandle(receiver), batch, MSG_DONTWAIT, 5) == InvalidInput
  for cycle in 0..<128:
    for packet in 1..4:
      var value = [byte(packet)]
      assert sendTo(sender, value, destination, afterMs(2000)) == 1
    for packet in 1..4:
      assert bounded(receiver, batch, 1) == 1
      assert datagramLen(batch, 0) == 1 and batch.slots[0].buf[0] == byte(packet)
      assert peerLen(batch, 0) > 0
      assert batch.cap == 4 and batch.hdrs.len == 4
    var empty = default(array[0, byte])
    assert sendTo(sender, empty, destination, afterMs(2000)) == 0
    assert bounded(receiver, batch, 0) == 1 and datagramLen(batch, 0) == 0
  freeBatch(batch)
  freeBatch(batch)
  assert batch.cap == 0 and batch.hdrs.len == 0
  assert recvmmsgBatch(nativeHandle(receiver), batch, MSG_DONTWAIT) == InvalidInput
  close(receiver)
  close(sender)
  echo "PASS bounded batches preserve capacity, addresses, datagram order, empty packets and full disposal"

assert runMain(main())
