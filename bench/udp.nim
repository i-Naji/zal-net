import std/[assertions, syncio, algorithm]
import zal_net/rt, zal_net/rt/sync
import zal_net/foundation/udp
import zal_net/raw/mmsg
import zal_net/net/address

const
  Peers {.intdefine.} = 8
  Rounds {.intdefine.} = 512
  Size {.intdefine.} = 64
  Window {.intdefine.} = 32
  Warmup = 32

when Peers <= 0 or Rounds <= 0 or Size < 9 or Size > UdpMax or
    Window <= 0 or Window > MaxBatchSlots:
  {.error: "Invalid UDP benchmark dimensions".}

type Lane = ref object
  client, server: UdpSocketRef
  ready, start, done, serverDone: Event
  samples: seq[int64]

proc packet(buffer: var openArray[byte]; sequence: int) =
  for i in 0..<8: buffer[i] = byte((uint64(sequence) shr (i * 8)) and 255)
  buffer[buffer.len - 1] = 165

proc checkPacket(buffer: openArray[byte]; sequence: int) =
  assert buffer.len == Size
  for i in 0..<8: assert buffer[i] == byte((uint64(sequence) shr (i * 8)) and 255)
  assert buffer[buffer.len - 1] == 165

template sendWindow(socket: UdpSocketRef; batch: var MmsgBatch;
                    target: SocketAddress; base: int) =
  when defined(benchBatch):
    for i in 0..<Window:
      packet(batch.slots[i].buf.toOpenArray(0, Size - 1), base + i)
    let sent = sendBatch(socket, batch, Window, afterMs(30000))
    assert sent.sent == Window and sent.error == 0
  else:
    var bytes = default(array[Size, byte])
    for i in 0..<Window:
      packet(bytes, base + i)
      assert sendTo(socket, bytes, target, afterMs(30000)) == Size

template receiveWindow(socket: UdpSocketRef; batch: var MmsgBatch; base: int) =
  when defined(benchBatch):
    var received = 0
    while received < Window:
      let count = recvBatch(socket, batch, afterMs(30000))
      assert count > 0 and count <= Window - received
      for i in 0..<count:
        assert datagramLen(batch, i) == Size
        checkPacket(batch.slots[i].buf.toOpenArray(0, Size - 1), base + received + i)
      received += count
  else:
    var bytes = default(array[Size, byte])
    var source = default(SocketAddress)
    for i in 0..<Window:
      assert recvFrom(socket, bytes, source, afterMs(30000)) == Size
      checkPacket(bytes, base + i)

template prepare(outgoing, incoming: var MmsgBatch; target: SocketAddress) =
  when defined(benchBatch):
    assert initBatch(outgoing, Window) and initBatch(incoming, Window)
    for i in 0..<Window: setOutgoing(outgoing, i, Size, target.raw)

template dispose(outgoing, incoming: var MmsgBatch) =
  when defined(benchBatch):
    freeBatch(outgoing)
    freeBatch(incoming)

proc serve(lane: sink Lane) {.passive.} =
  let target = localAddress(lane.client)
  var outgoing, incoming = default(MmsgBatch)
  prepare(outgoing, incoming, target)
  defer: dispose(outgoing, incoming)
  for round in 0..<(Warmup + Rounds):
    receiveWindow(lane.server, incoming, round * Window)
    sendWindow(lane.server, outgoing, target, round * Window)
  setEvent(addr lane.serverDone)

proc exchange(lane: sink Lane) {.passive.} =
  let target = localAddress(lane.server)
  var outgoing, incoming = default(MmsgBatch)
  prepare(outgoing, incoming, target)
  defer: dispose(outgoing, incoming)
  lane.samples = newSeq[int64](Rounds)
  for round in 0..<(Warmup + Rounds):
    if round == Warmup:
      setEvent(addr lane.ready)
      assert wait(addr lane.start, afterMs(30000)) == wrReady
    let started = monoNow()
    sendWindow(lane.client, outgoing, target, round * Window)
    receiveWindow(lane.client, incoming, round * Window)
    if round >= Warmup:
      lane.samples[round - Warmup] = int64(monoNow()) - int64(started)
  setEvent(addr lane.done)

proc main() {.passive.} =
  var lanes: seq[Lane] = @[]
  for i in 0..<Peers:
    let client = bindUdpRef(0, "127.0.0.1").value
    let server = bindUdpRef(0, "127.0.0.1").value
    assert client != nil and server != nil
    if client != nil and server != nil:
      let lane = Lane(client: client, server: server)
      lanes.add lane
      assert trySpawnTask(serve(lane))
      assert trySpawnTask(exchange(lane))
  for lane in lanes: assert wait(addr lane.ready, afterMs(30000)) == wrReady
  let started = monoNow()
  for lane in lanes: setEvent(addr lane.start)
  for lane in lanes: assert wait(addr lane.done, afterMs(30000)) == wrReady
  let elapsed = int64(monoNow()) - int64(started)
  var samples: seq[int64] = @[]
  for lane in lanes:
    assert wait(addr lane.serverDone, afterMs(30000)) == wrReady
    assert close(lane.client) == 0 and close(lane.server) == 0
    for sample in lane.samples: samples.add sample
  samples.sort()
  const Mode = when defined(benchBatch): "batch" else: "scalar"
  # Both directions count toward packet rate; latency covers one full window.
  echo "protocol=udp mode=", Mode, " workers=", runtimeWorkers(), " peers=", Peers,
       " bytes=", Size, " window=", Window, " rounds=", Rounds,
       " packets=", Peers * Rounds * Window * 2, " elapsed_ns=", elapsed,
       " window_p50_ns=", samples[samples.len div 2],
       " window_p99_ns=", samples[(samples.len * 99) div 100]

assert runMain(main())
