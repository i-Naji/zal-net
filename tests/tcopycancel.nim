## A cancelled copy preserves owners; relay cancellation drains both pumps.
import std/[assertions, syncio]
import zal_net/raw
import zal_net/raw/io
import zal_net/errors

type LegacyStream = object
  calls: int
type LegacyStreamPtr = ptr LegacyStream

proc recvInto(s: LegacyStreamPtr; buf: pointer; count: int; until: Deadline): int {.passive.} =
  s.calls = s.calls + 1
  result = 0
proc sendFrom(s: LegacyStreamPtr; buf: pointer; count: int; until: Deadline): int {.passive.} =
  s.calls = s.calls + 1
  result = count
proc shutdownWrite(s: LegacyStreamPtr) = s.calls = s.calls + 1
proc interrupt(s: LegacyStreamPtr) = s.calls = s.calls + 1

proc cancelSoon(tok: CancelToken; done: ptr Event) {.passive.} =
  parkUntil(afterMs(20))
  cancel(tok)
  release(tok)
  setEvent(done)

proc main() {.passive.} =
  let baseline = liveCancelTokens()
  var legacy = default(LegacyStream)
  let required = newCancelToken()
  let refusedCopy = copy(addr legacy, addr legacy, tok = required)
  let refusedRelay = relay(addr legacy, addr legacy, tok = required)
  assert refusedCopy.error == NotSupported
  assert refusedRelay.aToB.error == NotSupported and refusedRelay.bToA.error == NotSupported
  assert legacy.calls == 0
  release(required)
  var listener = listenTcp(0, "127.0.0.1")
  assert listener.ok
  var upstream = connect("127.0.0.1", listener.port)
  var source = accept(listener)
  var destination = connect("127.0.0.1", listener.port)
  var downstream = accept(listener)
  assert upstream.isOpen and source.isOpen and destination.isOpen and downstream.isOpen
  let tok = newCancelToken()
  var done = default(Event)
  retain(tok)
  assert trySpawnTask(cancelSoon(tok, addr done))
  let stopped = copy(addr source, addr destination, idleMs = 2000, splice = false, tok = tok)
  assert stopped.bytes == 0 and stopped.error == ECancelled
  assert wait(addr done, afterMs(2000)) == wrReady
  release(tok)
  var payload = [42'u8]
  var received = default(array[1, byte])
  assert sendFrom(addr upstream, payload) == 1
  assert recvInto(addr source, received, afterMs(2000)) == 1 and received == payload
  assert sendFrom(addr destination, payload) == 1
  assert recvInto(addr downstream, received, afterMs(2000)) == 1 and received == payload
  var reader = initBufReader(addr source, 64)
  var empty = default(array[0, byte])
  assert recvInto(addr reader, empty) == 0
  assert recvInto(addr reader, addr received[0], -1) == InvalidInput
  assert not readExactly(addr reader, addr received[0], -1)
  var line = "unchanged"
  assert readLine(addr reader, addr line, maxLen = high(int)) == InvalidInput
  assert line == "unchanged"
  let readToken = newCancelToken()
  var readDone = default(Event)
  retain(readToken)
  assert trySpawnTask(cancelSoon(readToken, addr readDone))
  assert recvInto(addr reader, received, afterMs(2000), readToken) == ECancelled
  assert wait(addr readDone, afterMs(2000)) == wrReady
  release(readToken)
  assert sendFrom(addr upstream, payload) == 1
  assert fill(addr reader, afterMs(2000)) == 1
  consume(addr reader, -1)
  assert buffered(addr reader) == 1
  let stoppedRead = newCancelToken()
  cancel(stoppedRead)
  assert recvInto(addr reader, received, tok = stoppedRead) == ECancelled
  assert buffered(addr reader) == 1
  release(stoppedRead)
  assert readExactly(addr reader, received) and received == payload
  let relayToken = newCancelToken()
  var relayDone = default(Event)
  retain(relayToken)
  assert trySpawnTask(cancelSoon(relayToken, addr relayDone))
  let relayed = relay(addr source, addr destination, idleMs = 2000, splice = false, tok = relayToken)
  assert relayed.aToB.error == ECancelled or relayed.bToA.error == ECancelled
  assert wait(addr relayDone, afterMs(2000)) == wrReady
  release(relayToken)
  close(addr upstream)
  close(addr source)
  close(addr destination)
  close(addr downstream)
  closeNow(listener)
  assert liveCancelTokens() == baseline
  echo "PASS copy/buffered-read owner reuse, bounds, adapter rejection and relay drain"

assert runMain(main())
