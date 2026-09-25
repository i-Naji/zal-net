## Per-operation cancellation must not destroy the socket or listener. Every
## pending operation retains its token until its readiness poll has completed.
import std/[assertions, syncio]
import zal_net/rt, zal_net/raw/io, zal_net/rt/[sync, cancel]
import zal_net/raw/[tcp, udp, unix, mmsg], zal_net/net/[address, stream]
import zal_net/errors

proc cancelSoon(tok: CancelToken; done: ptr Event) {.passive.} =
  sleepMs(20)
  cancel(tok)
  release(tok)                    # this task owns one retained reference
  setEvent(done)

proc scheduleCancel(tok: CancelToken; done: ptr Event) =
  retain(tok)
  assert trySpawnTask(cancelSoon(tok, done)), "tiocancel check 16"

proc main() {.passive.} =
  let baseline = liveCancelTokens()
  var listener = listenTcp(0, "127.0.0.1")
  assert listener.ok, "tiocancel check 21"
  let acceptToken = newCancelToken()
  var acceptDone = default(Event)
  scheduleCancel(acceptToken, addr acceptDone)
  var rejected = accept(listener, tok = acceptToken, deadline = afterMs(2000))
  assert not rejected.isOpen, "tiocancel check 26"
  assert wait(addr acceptDone, afterMs(2000)) == wrReady, "tiocancel check 27"
  release(acceptToken)
  assert listener.ok, "tiocancel check 29"

  var client = connect("localhost", listener.port)
  assert client.isOpen, "tiocancel check 32"
  var server = accept(listener, deadline = afterMs(2000))
  assert server.isOpen, "tiocancel check 34"
  var bytes = default(array[16, byte])
  for iteration in 0..<100:
    let tok = newCancelToken()
    var done = default(Event)
    scheduleCancel(tok, addr done)
    assert recvInto(addr server, bytes, afterMs(2000), tok) == ECancelled, "tiocancel check 40"
    assert wait(addr done, afterMs(2000)) == wrReady, "tiocancel check 41"
    release(tok)
    assert server.isOpen, "tiocancel check 43"
    var payload = [byte(iteration)]
    assert sendFrom(addr client, payload, afterMs(2000)) == 1, "tiocancel check 45"
    assert recvInto(addr server, bytes, afterMs(2000)) == 1, "tiocancel check 46"
    assert bytes[0] == payload[0], "tiocancel check 47"

  # Cancellation observed before the syscall must leave queued data untouched.
  let cancelledToken = newCancelToken()
  cancel(cancelledToken)
  var payload = [42'u8]
  assert sendFrom(addr client, payload) == 1, "tiocancel check 53"
  assert recvInto(addr server, bytes, tok = cancelledToken) == ECancelled, "tiocancel check 54"
  assert sendFrom(addr server, payload, tok = cancelledToken) == ECancelled, "tiocancel check 55"
  assert recvInto(addr server, bytes) == 1 and bytes[0] == 42, "tiocancel check 56"
  assert not connect("localhost", listener.port, tok = cancelledToken).isOpen, "tiocancel check 57"
  assert not connect(initSocketAddress(loopback4(), listener.port), tok = cancelledToken).isOpen, "tiocancel check 58"
  release(cancelledToken)

  # An empty byte window never performs I/O, including under cancellation.
  var empty = default(array[0, byte])
  assert recvInto(addr server, empty, afterMs(1)) == 0, "tiocancel check 63"
  assert sendFrom(addr server, empty, afterMs(1)) == 0, "tiocancel check 64"
  var reader = initBufReader(addr server, 32)
  let before = monoNow()
  assert readUntil(addr reader, "", deadline = afterMs(500)) == InvalidInput, "tiocancel check 67"
  assert int64(monoNow()) - int64(before) < 100_000_000, "tiocancel check 68"

  # Deadline expiry on accept is also local to that wait.
  assert not accept(listener, deadline = afterMs(10)).isOpen, "tiocancel check 71"
  assert listener.ok, "tiocancel check 72"
  close(addr client)
  close(addr server)
  closeNow(listener)
  var sender = bindUdp(0, "127.0.0.1")
  var receiver = bindUdp(0, "127.0.0.1", timeoutMs = 0)
  assert sender.ok and receiver.ok, "UDP bind"
  let destination = localAddress(receiver)
  var source = default(SocketAddress)
  let sent = sendTo(sender, empty, destination, afterMs(2000))
  assert sent == 0, "empty UDP send " & $sent
  let received = recvFrom(receiver, empty, source, afterMs(2000))
  assert received == 0, "empty UDP recv " & $received
  assert port(source) == port(localAddress(sender)), "UDP source port " & $port(source)
  let timeout = recvFrom(receiver, bytes, source, afterMs(10))
  assert timeout == IoTimedOut, "UDP read deadline result " & $timeout
  var info = default(DatagramInfo)
  assert recvFrom(receiver, addr bytes[0], -1, addr info) == InvalidInput
  assert sendWithSource(sender, addr bytes[0], -1, destination, loopback4()) == InvalidInput
  assert send(sender, addr bytes[0], -1) == InvalidInput
  assert recv(receiver, addr bytes[0], -1) == InvalidInput
  var batch = default(MmsgBatch)
  assert not initBatch(batch, 0), "UDP cancellation check 94"
  assert not initBatch(batch, MaxBatchSlots + 1), "UDP cancellation check 95"
  assert batch.cap == 0, "UDP cancellation check 96"
  assert initBatch(batch, 2), "UDP cancellation check 97"
  assert not initBatch(batch, 2), "reinitializing a live batch rejects without losing storage"
  assert sendBatch(sender, addr batch, -1) == InvalidInput, "UDP cancellation check 99"
  assert sendBatch(sender, addr batch, 3) == InvalidInput, "UDP cancellation check 100"
  let udpToken = newCancelToken()
  var udpDone = default(Event)
  scheduleCancel(udpToken, addr udpDone)
  assert recvBatch(receiver, addr batch, afterMs(2000), udpToken) == ECancelled, "UDP cancellation check 104"
  assert wait(addr udpDone, afterMs(2000)) == wrReady, "UDP cancellation check 105"
  release(udpToken)
  var one = [7'u8]
  assert sendTo(sender, one, destination) == 1, "UDP cancellation check 108"
  assert recvBatch(receiver, addr batch, afterMs(2000)) == 1, "UDP cancellation check 109"
  assert datagramLen(batch, 0) == 1 and batch.slots[0].buf[0] == 7, "UDP cancellation check 110"
  freeBatch(batch)
  freeBatch(batch)
  assert batch.cap == 0 and batch.hdrs.len == 0, "UDP cancellation check 113"
  assert recvBatch(receiver, addr batch) == InvalidInput, "UDP cancellation check 114"

  let stoppedUdp = newCancelToken()
  cancel(stoppedUdp)
  assert sendTo(sender, empty, destination, tok = stoppedUdp) == ECancelled, "UDP cancellation check 118"
  assert recvFrom(receiver, empty, source, tok = stoppedUdp) == ECancelled, "UDP cancellation check 119"
  assert recvFrom(receiver, bytes, info, tok = stoppedUdp) == ECancelled, "UDP cancellation check 120"
  assert sendWithSource(sender, one, destination, loopback4(), tok = stoppedUdp) == ECancelled, "UDP cancellation check 121"
  assert not connectUdp("localhost", port(destination), tok = stoppedUdp).ok, "UDP cancellation check 122"
  release(stoppedUdp)

  var connected = connectUdp(destination)
  assert connected.ok, "UDP cancellation check 126"
  let connectedToken = newCancelToken()
  var connectedDone = default(Event)
  scheduleCancel(connectedToken, addr connectedDone)
  assert recv(connected, bytes, afterMs(2000), connectedToken) == ECancelled, "UDP cancellation check 130"
  assert wait(addr connectedDone, afterMs(2000)) == wrReady, "UDP cancellation check 131"
  release(connectedToken)
  assert sendTo(receiver, one, localAddress(connected)) == 1, "UDP cancellation check 133"
  assert recv(connected, bytes, afterMs(2000)) == 1 and bytes[0] == 7, "UDP cancellation check 134"
  close(connected)
  close(sender)
  close(receiver)
  assert liveCancelTokens() == baseline, "tokens left " & $liveCancelTokens() & " baseline " & $baseline
  echo "PASS cancelled accept/read preserve owners; 100 reuse cycles, empty windows/datagrams and bounds"

assert runMain(main())
