## Unix application owners: byte I/O, exact failures and draining accepts.
import std/[assertions, syncio, envvars]
import zal_net/rt, zal_net/rt/sync
import zal_net/rt/cancel as cancellation
import zal_net/net/unix as local
import zal_net/errors as rawerrors
from zal_net/foundation/unix import nativeHandle
import zal_net/net/options
from zal_net/private/sys/sock import getPid

type AcceptContext = ref object
  entered, done: Event
  token: nil CancelToken
  error: ErrorCode

type ReadContext = ref object
  entered, done: Event
  count: int
  error: ErrorCode

proc pendingRead(stream: sink local.UnixStream; ctx: sink ReadContext) {.passive.} =
  try:
    var bytes = default(array[3, byte])
    setEvent(addr ctx.entered)
    ctx.count = stream.read(bytes, deadline=afterMs(2000))
    assert bytes[0] == 31 and bytes[2] == 42
  except ErrorCode as error:
    ctx.error = error
  setEvent(addr ctx.done)

proc pendingAccept(server: sink local.UnixListener; ctx: sink AcceptContext) {.passive.} =
  try:
    setEvent(addr ctx.entered)
    let stream = server.accept(deadline=afterMs(5000), cancel=ctx.token)
    stream.close()
  except ErrorCode as error:
    ctx.error = error
  setEvent(addr ctx.done)

proc countedDeadline(calls: var int): Deadline =
  inc calls
  afterMs(30)

proc countedToken(calls: var int; token: CancelToken): CancelToken =
  inc calls
  token

proc socketPath(): string =
  when defined(windows): getEnv("TEMP") & "\\nn-application-unix-" & $getPid() & ".sock"
  else: "/tmp/nn-application-unix-" & $getPid() & ".sock"

proc exercise() {.passive, raises.} =
  let path = socketPath()
  let server = local.listen(path)
  defer: server.close()
  assert server.path == path
  try:
    discard local.listen(path)
    assert false
  except ErrorCode as error:
    assert error == BusyError
  # Existing stale-path detection probes a live socket. Drain that connection.
  let probe = server.accept(deadline=afterMs(2000))
  var bytes = [31'u8, 73, 42]
  assert probe.read(bytes, deadline=afterMs(2000)) == 0
  probe.close()
  for invalidBacklog in [0, -1, high(int)]:
    try:
      discard local.listen(path, backlog=invalidBacklog)
      assert false
    except ErrorCode as error:
      assert error == ValueError
  try:
    discard local.listen("")
    assert false
  except ErrorCode as error:
    assert error == ValueError
  try:
    discard server.accept(deadline=afterMs(0))
    assert false
  except ErrorCode as error:
    assert error == TimeoutError

  let token = cancellation.newCancelToken()
  defer: cancellation.release(token)
  let ctx = AcceptContext(token: token)
  assert trySpawnTask(pendingAccept(server, ctx))
  assert wait(addr ctx.entered, afterMs(2000)) == wrReady
  try:
    discard server.accept()
    assert false
  except ErrorCode as error:
    assert error == BusyError
  cancellation.cancel(token)
  assert wait(addr ctx.done, afterMs(2000)) == wrReady
  assert ctx.error == AbortedOperation

  # The cancelled accept leaves the listener usable.
  let client = local.connect(path, deadline=afterMs(2000))
  defer: client.close()
  let peer = server.accept(deadline=afterMs(2000))
  defer: peer.close()
  client.write(bytes, deadline=afterMs(2000))
  assert peer.read(bytes, deadline=afterMs(2000)) == 3
  assert bytes[0] == 31 and bytes[2] == 42
  assert client.lastWriteFailure.code == 0
  assert client.lastWriteFailure.transferred == 3
  var empty = default(array[0, byte])
  assert peer.read(empty) == 0
  peer.write(empty)
  try:
    discard peer.read(bytes, cancel=token)
    assert false
  except ErrorCode as error:
    assert error == AbortedOperation
    assert peer.lastReadFailure.code == ECancelled

  assert setSendBuffer(nativeHandle(client), 4096)
  let payload = newSeq[byte](4 * 1024 * 1024)
  let writeToken = cancellation.newCancelToken()
  defer: cancellation.release(writeToken)
  var deadlineCalls, tokenCalls = 0
  try:
    client.write(payload, deadline=countedDeadline(deadlineCalls),
                 cancel=countedToken(tokenCalls, writeToken))
    assert false
  except ErrorCode as error:
    assert error == TimeoutError
  let progress = client.lastWriteFailure
  assert progress.code == IoTimedOut
  assert progress.transferred > 0 and progress.transferred < payload.len
  assert deadlineCalls == 1 and tokenCalls == 1
  var drained = 0
  var window = default(array[4096, byte])
  while drained < progress.transferred:
    let count = peer.read(window, deadline=afterMs(2000))
    assert count > 0
    drained += count
  assert drained == progress.transferred

  # Half-close the writer while a read is pending; reading stays usable.
  let reader = ReadContext()
  assert trySpawnTask(pendingRead(peer, reader))
  assert wait(addr reader.entered, afterMs(2000)) == wrReady
  peer.shutdownWrite()
  assert client.read(bytes, deadline=afterMs(2000)) == 0
  client.write(bytes)
  assert wait(addr reader.done, afterMs(2000)) == wrReady
  assert reader.error == Success and reader.count == 3

  let closing = AcceptContext()
  assert trySpawnTask(pendingAccept(server, closing))
  assert wait(addr closing.entered, afterMs(2000)) == wrReady
  try:
    server.close(deadline=afterMs(0))
  except ErrorCode as error:
    assert error == TimeoutError
  server.close(deadline=afterMs(2000))
  assert wait(addr closing.done, afterMs(2000)) == wrReady
  assert closing.error == DeadResource
  server.close()
  var file: File
  assert not open(file, path)
  # Closing a listener leaves already accepted streams owned by their callers.
  client.write(bytes)
  assert peer.read(bytes, deadline=afterMs(2000)) == 3
  client.shutdownWrite()
  assert peer.read(bytes, deadline=afterMs(2000)) == 0
  peer.close()
  peer.close()
  try:
    peer.write(empty)
    assert false
  except ErrorCode as error:
    assert error == DeadResource
    assert peer.lastWriteFailure.code == rawerrors.ResourceClosed
  try:
    discard local.connect(path, deadline=afterMs(2000))
    assert false
  except ErrorCode as error:
    assert error != Success

proc main() {.passive.} =
  try:
    exercise()
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false
  assert cancellation.liveCancelTokens() == 0
  echo "PASS application Unix streams, cancellation, partial writes and listener drain"

assert runMain(main())
