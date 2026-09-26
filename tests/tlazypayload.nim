## Payload buffers are separately owned, lazy, pooled and reclaimed only idle.
import std/[assertions, syncio, atomics]
import zal_net/rt, zal_net/raw/io
import zal_net/raw/socket
import zal_net/relay

var endings: int
proc ended(c: Conn) =
  assert c.endReason == erEof or (defined(nnRelayFaultTest) and c.endReason == erError)
  discard atomicFetchAdd(endings, 1, moRelease)
var hooks = ConnHooks(onEnd: ended)

proc run(c: Conn) {.passive.} = startPumps(c)
proc made(left, right: cint; framed: nil Framer = nil): Conn =
  let candidate = newConn(2000, payloadIdleMs=20)
  assert candidate != nil
  if candidate == nil: quit "connection admission failed"
  result = candidate
  result.fd = left
  result.up = right
  result.hooks = addr hooks
  result.a.src = left
  result.a.dst = right
  result.a.srcFramer = framed
  result.b.src = right
  result.b.dst = left

proc emptyBuffers() {.passive.} =
  let deadline = afterMs(1000)
  while livePayloadBuffers() != 0:
    assert monoNow() < deadline, "idle payload did not reclaim"
    parkUntil(afterMs(1))

proc frameOpen(c: Conn; d: DirectionPtr): int =
  if d.fill - d.off < 2: return 0
  let size = int(d.buf[d.off])
  if d.fill - d.off < size + 1: return 0
  d.spans[0] = Span(off: d.off + 1, len: size)
  d.nspans = 1
  d.bytes = size
  d.off = d.off + size + 1
  result = 1
proc boundary(d: DirectionPtr): bool = d.off == d.fill
proc seal(c: Conn; d: DirectionPtr): bool = false
proc noClose(d: DirectionPtr) = discard
var fixtureFramer = FramerObj(geometry: Geometry(head: 1, maxRecord: 64),
  open: frameOpen, atBoundary: boundary, seal: seal, closeSource: noClose, closeSink: noClose)

proc finishPeers(client, sink: cint; expectedEnds: int) {.passive.} =
  shutdownWrite(client)
  shutdownWrite(sink)
  var value = 0'u8
  assert waitRead(client, addr value, 1, 2000) == 0
  assert waitRead(sink, addr value, 1, 2000) == 0
  closeFd(client)
  closeFd(sink)
  let deadline = afterMs(2000)
  while atomicLoad(endings, moAcquire) != expectedEnds or liveConnections() != 0:
    assert monoNow() < deadline
    parkUntil(afterMs(1))

var producerDone: int
const BackpressureBytes = 2 * 1024 * 1024
proc producer(fd: cint) {.passive.} =
  var data = default(array[32768, byte])
  for i in 0..<data.len: data[i] = 43
  var sent = 0
  while sent < BackpressureBytes:
    assert writeAll(fd, addr data[0], data.len, 2000)
    sent += data.len
  atomicStore(producerDone, 1, moRelease)

proc main() {.passive.} =
  let fresh = newConn(0)
  assert fresh != nil
  if fresh != nil:
    assert not hasPayload(addr fresh.a) and not hasPayload(addr fresh.b)
    assert livePayloadBuffers() == 0
    when defined(nnRelayFaultTest):
      failNextPayloadAllocation()
      assert not ensurePayload(addr fresh.a) and not hasPayload(addr fresh.a)
      assert livePayloadBuffers() == 0
    freeConn(fresh)
  let (client, ingress) = openPair()
  let (egress, sink) = openPair()
  let c = made(ingress, egress)
  assert trySpawnTask(run(c))
  parkUntil(afterMs(30))
  assert liveConnections() == 1 and livePayloadBuffers() == 0, "idle accept has no payload"
  var data = default(array[8192, byte])
  var reply = default(array[8192, byte])
  for i in 0..<data.len: data[i] = byte(i and 255)
  var warmMaps = 0
  for cycle in 0..<24:
    assert writeAll(client, addr data[0], data.len, 2000)
    var used = 0
    while used < reply.len:
      let count = waitRead(sink, addr reply[used], reply.len - used, 2000)
      assert count > 0
      used += count
    assert reply == data
    emptyBuffers()
    assert liveConnections() == 1 and atomicLoad(endings, moAcquire) == 0
    if cycle == 0: warmMaps = payloadMappingCalls()
    else: assert payloadMappingCalls() == warmMaps, "idle/reacquire uses retained pool"
  finishPeers(client, sink, 1)
  let (source, middleA) = openPair()
  let (middleB, target) = openPair()
  let framed = made(middleA, middleB, addr fixtureFramer)
  assert trySpawnTask(run(framed))
  var head = 3'u8
  assert writeAll(source, addr head, 1, 2000)
  parkUntil(afterMs(60))
  assert livePayloadBuffers() == 1, "incomplete record must retain its payload"
  var tail = [17'u8, 18, 19]
  assert writeAll(source, addr tail[0], 3, 2000)
  var got = default(array[3, byte])
  var used = 0
  while used < got.len:
    let n = waitRead(target, addr got[used], got.len - used, 2000)
    assert n > 0
    used += n
  assert got == tail
  emptyBuffers()
  finishPeers(source, target, 2)
  let (writing, blockedIn) = openPair()
  let (blockedOut, reading) = openPair()
  let blocked = made(blockedIn, blockedOut)
  assert trySpawnTask(run(blocked))
  assert trySpawnTask(producer(writing))
  parkUntil(afterMs(60))
  assert atomicLoad(producerDone, moAcquire) == 0, "sink must apply real backpressure"
  assert livePayloadBuffers() > 0, "pending output cannot release payload"
  var received = 0
  while received < BackpressureBytes:
    let n = waitRead(reading, addr reply[0], reply.len, 2000)
    assert n > 0
    for i in 0..<n: assert reply[i] == 43
    received += n
  let producerDeadline = afterMs(2000)
  while atomicLoad(producerDone, moAcquire) == 0:
    assert monoNow() < producerDeadline
    parkUntil(afterMs(1))
  emptyBuffers()
  finishPeers(writing, reading, 3)
  echo "RELAY MEMORY metadata_bytes=", relayMetadataBytes(),
    " live_payloads=", livePayloadBuffers(), " retained_payloads=", retainedPayloadBuffers(),
    " payload_capacity=", BufCap, " mapping_calls=", payloadMappingCalls()
  assert stopRelayPool()
  assert livePayloadBuffers() == 0 and retainedPayloadBuffers() == 0
  echo "PASS lazy first traffic, idle reuse, partial-record retention and pool shutdown"

assert runMain(main())
