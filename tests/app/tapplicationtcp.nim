## Ordinary TCP API and value-error propagation across real I/O suspension.
import std/[assertions, syncio]
import zal_net
import zal_net/rt/cancel as cancellation
import zal_net/errors as rawerrors
from zal_net/foundation/tcp import nativeHandle
from zal_net/foundation/tcplistener import nativeHandle
import zal_net/net/options

proc countedDeadline(calls: var int): Deadline =
  inc calls
  afterMs(30)

proc countedToken(calls: var int; token: CancelToken): CancelToken =
  inc calls
  token

template nestedWrite(stream: TcpStream; bytes: openArray[byte]) =
  stream.write(bytes, deadline=afterMs(2000))

proc exercise() {.passive, raises.} =
  let server = listen(0, "127.0.0.1")
  defer: server.close()
  assert setRecvBuffer(nativeHandle(server), 4096), "bound accepted TCP receive window before handshake"
  let client = connect("127.0.0.1", server.port, deadline=afterMs(2000))
  defer: client.close()
  let peer = server.accept(deadline=afterMs(2000))
  defer: peer.close()
  var bytes = [31'u8, 73, 42]
  nestedWrite(client, bytes)
  let firstRead = peer.read(bytes, deadline=afterMs(2000))
  echo "TCP initial write/read: sent=", client.lastWriteFailure.transferred, " read=", firstRead
  assert firstRead == 3, "initial TCP read receives three queued bytes"
  assert bytes[0] == 31 and bytes[2] == 42, "initial TCP payload intact"
  assert client.lastWriteFailure.code == 0, "initial write records success"
  assert client.lastWriteFailure.transferred == 3, "initial full write reports all bytes"

  var empty = default(array[0, byte])
  assert peer.read(empty) == 0, "empty TCP read is immediate"
  peer.write(empty)
  assert peer.lastWriteFailure.transferred == 0, "empty TCP write records zero bytes"

  # Hold the receiver idle and constrain the sender window. The full-write
  # operation must preserve the count already delivered when its wait expires.
  assert setSendBuffer(nativeHandle(client), 4096), "configure sender backpressure"
  let payload = newSeq[byte](4 * 1024 * 1024)
  let writeToken = cancellation.newCancelToken()
  defer: cancellation.release(writeToken)
  var deadlineCalls, tokenCalls = 0
  try:
    client.write(payload, deadline=countedDeadline(deadlineCalls),
                 cancel=countedToken(tokenCalls, writeToken))
    echo "TCP full-write completed: native=", client.lastWriteFailure.code, " bytes=", client.lastWriteFailure.transferred
    assert false, "backpressure must prevent completing the oversized write"
  except ErrorCode as error:
    echo "TCP partial-write failure: ", error, " native=", client.lastWriteFailure.code, " bytes=", client.lastWriteFailure.transferred
    assert error == TimeoutError, "blocked full write reports TimeoutError"
  let progress = client.lastWriteFailure
  assert progress.code == IoTimedOut, "full write reports its timeout"
  assert progress.transferred > 0 and progress.transferred < payload.len, "timeout preserves partial write progress"
  echo "TCP partial-write arguments: deadlines=", deadlineCalls, " tokens=", tokenCalls
  assert deadlineCalls == 1 and tokenCalls == 1
  var drained = 0
  var window = default(array[4096, byte])
  while drained < progress.transferred:
    let count = peer.read(window, deadline=afterMs(2000))
    assert count > 0, "peer drains every reported partial-write byte"
    drained += count
  assert drained == progress.transferred

  try:
    discard peer.read(bytes, deadline=afterMs(0))
    assert false
  except ErrorCode as error:
    assert error == TimeoutError
    assert peer.lastReadFailure.code == IoTimedOut

  let stopped = cancellation.newCancelToken()
  defer: cancellation.release(stopped)
  cancellation.cancel(stopped)
  try:
    discard peer.read(bytes, cancel=stopped)
    assert false
  except ErrorCode as error:
    assert error == AbortedOperation
    assert peer.lastReadFailure.code == ECancelled

  client.shutdownWrite()
  assert peer.read(bytes, deadline=afterMs(2000)) == 0, "TCP half-close reaches EOF"
  peer.close()
  peer.close()
  try:
    discard peer.read(bytes)
    assert false
  except ErrorCode as error:
    assert error == DeadResource
    assert peer.lastReadFailure.code == rawerrors.ResourceClosed
  try:
    peer.write(empty)
    assert false
  except ErrorCode as error:
    assert error == DeadResource
    assert peer.lastWriteFailure.code == rawerrors.ResourceClosed

  let rejected = listen(0, "127.0.0.1")
  let refusedPort = rejected.port
  rejected.close()
  try:
    discard connect("127.0.0.1", refusedPort, deadline=afterMs(5000))
    assert false
  except ErrorCode as error:
    assert error == RefusedConnection

proc main() {.passive.} =
  try:
    exercise()
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false
  assert cancellation.liveCancelTokens() == 0
  echo "PASS application TCP, timeout, cancellation, EOF and repeated close"

assert runMain(main())
