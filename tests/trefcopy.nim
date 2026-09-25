## Flat friendly copying retains both owners and drains cancellation/close.
import std/[assertions, syncio]
import zal_net/raw
import zal_net/errors
import zal_net/raw/[io, socket]
import zal_net/foundation/tcp
import zal_net/net/stream as rawcopy

type State = object
  done: Event
  outcome: rawcopy.CopyStats
proc pump(source, destination: sink TcpConnRef; tok: nil CancelToken;
          state: ptr State) {.passive.} =
  state.outcome = copy(source, destination, splice = false, tok = tok)
  discard shutdownWrite(destination)
  setEvent(addr state.done)
proc takeOwner(fd: var cint): nil TcpConnRef =
  var raw = default(TcpStream)
  assert adoptTcp(addr raw, fd)
  result = takeTcpConn(raw).value
  assert result != nil
proc main() {.passive.} =
  let (writer, inputFd) = openPair()
  let (outputFd, reader) = openPair()
  var input = inputFd
  var output = outputFd
  var state = default(State)
  block:
    let source = takeOwner(input)
    let destination = takeOwner(output)
    if source != nil and destination != nil:
      assert copy(source, source, splice = false).error == InvalidInput
      let stopped = newCancelToken()
      cancel(stopped)
      assert copy(source, destination, splice = false, tok = stopped).error == ECancelled
      assert quiescent(source) and quiescent(destination)
      release(stopped)
      assert trySpawnTask(pump(source, destination, nil, addr state))
    else:
      quit "owner construction failed"
  # The root's references have left scope before the queued pump starts.
  var bytes = default(array[16384, byte])
  for i in 0..<bytes.len: bytes[i] = byte(i and 255)
  assert writeAll(writer, addr bytes[0], bytes.len, 2000)
  shutdownWrite(writer)
  var received = default(array[16384, byte])
  var count = 0
  while count < received.len:
    let progress = waitRead(reader, addr received[count], received.len - count, 2000)
    assert progress > 0
    count = count + progress
  assert received == bytes
  assert wait(addr state.done, afterMs(2000)) == wrReady
  assert state.outcome.error == 0 and state.outcome.bytes == int64(bytes.len)
  closeFd(writer)
  closeFd(reader)

  for closeSource in [true, false]:
    let (quietWriter, quietInput) = openPair()
    let (quietOutput, quietReader) = openPair()
    var input2 = quietInput
    var output2 = quietOutput
    let reading = takeOwner(input2)
    let writing = takeOwner(output2)
    if reading != nil and writing != nil:
      var closing = default(State)
      assert trySpawnTask(pump(reading, writing, nil, addr closing))
      parkUntil(afterMs(20))
      var byteBuffer = [1'u8]
      assert recvInto(reading, byteBuffer) == ResourceBusy
      assert sendFrom(writing, byteBuffer) == ResourceBusy
      if closeSource:
        assert close(reading, afterMs(2000)) == 0, "source close drains a quiet copy"
      else:
        assert close(writing, afterMs(2000)) == 0, "destination close drains a quiet copy"
      assert wait(addr closing.done, afterMs(2000)) == wrReady
      assert closing.outcome.error == ResourceClosed
      assert close(reading) == 0 and close(writing) == 0
    else:
      quit "owner construction failed"
    closeFd(quietWriter)
    closeFd(quietReader)
  echo "PASS friendly copy data, retained owners, cancellation, busy admission and close drain"
assert runMain(main())
