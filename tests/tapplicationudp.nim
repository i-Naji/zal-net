## Datagram boundaries, empty windows, truncation and directional error state.
import std/[assertions, syncio]
import zal_net/rt
import zal_net/rt/cancel as cancellation
import zal_net/errors as rawerrors
import zal_net/net/udp

var payloadCalls = 0
proc payload(): array[3, byte] =
  inc payloadCalls
  [11'u8, 22, 33]

proc exercise() {.passive, raises.} =
  let receiver = bindUdp(0, "127.0.0.1", timeoutMs=0)
  defer: receiver.close()
  let sender = connectUdp("127.0.0.1", localAddress(receiver).port)
  defer: sender.close()
  let unconnected = openUdp()
  defer: unconnected.close()
  var bytes = default(array[8, byte])
  var source = default(SocketAddress)
  var empty = default(array[0, byte])
  sender.write(empty, deadline=afterMs(2000))
  assert receiver.recvFrom(bytes, source, afterMs(2000)) == 0
  assert source.port == localAddress(sender).port
  receiver.sendTo(payload(), source, deadline=afterMs(2000))
  assert payloadCalls == 1
  assert sender.read(bytes, afterMs(2000)) == 3
  assert bytes[0] == 11 and bytes[2] == 33
  assert receiver.lastWriteFailure.transferred == 3
  unconnected.sendTo([7'u8], localAddress(receiver), deadline=afterMs(2000))
  assert receiver.recvFrom(empty, source, afterMs(2000)) == 0
  try:
    discard receiver.recvFrom(bytes, source, afterMs(10))
    assert false
  except ErrorCode as error:
    assert error == TimeoutError
    assert receiver.lastReadFailure.code == IoTimedOut
    assert receiver.lastReadFailure.transferred == 0
  var info = default(DatagramInfo)
  var small = default(array[1, byte])
  sender.write([1'u8, 2, 3], deadline=afterMs(2000))
  assert receiver.recvFrom(small, info, afterMs(2000)) == 1
  assert info.truncated and small[0] == 1
  # The discarded tail must never become another packet.
  sender.write([9'u8], deadline=afterMs(2000))
  assert receiver.recvFrom(bytes, source, afterMs(2000)) == 1 and bytes[0] == 9
  let token = newCancelToken()
  cancellation.cancel(token)
  try:
    discard receiver.recvFrom(bytes, source, cancel=token)
    assert false
  except ErrorCode as error:
    assert error == AbortedOperation
    assert receiver.lastReadFailure.code == ECancelled
  release(token)
  let oversized = newSeq[byte](70_000)
  try:
    sender.write(oversized, deadline=afterMs(2000))
    assert false
  except ErrorCode as error:
    assert error == ContentTooLong
    assert sender.lastWriteFailure.code < 0
    assert sender.lastWriteFailure.transferred == 0
  try:
    discard bindUdp(0, "127.0.0.1\0suffix")
    assert false
  except ErrorCode as error:
    assert error == ValueError
  receiver.close()
  receiver.close()
  try:
    receiver.sendTo(empty, source)
    assert false
  except ErrorCode as error:
    assert error == DeadResource
    assert receiver.lastWriteFailure.code == rawerrors.ResourceClosed
    assert receiver.lastWriteFailure.transferred == 0
  echo "PASS application UDP boundaries and errors"

proc main() {.passive.} =
  try:
    exercise()
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
