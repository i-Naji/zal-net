{.feature: "assumeSync".}
## UDP owner transfer, operation cancellation, close drain and token reuse.
import std/[assertions, syncio]
import zal_net/[rt, errors], zal_net/rt/[sync, cancel, blocking]
import zal_net/raw/[udp, mmsg], zal_net/foundation/udp, zal_net/net/address, zal_net/net/sockaddr
when not defined(release):
  from zal_net/private/core/cancelstate import cancelTokenAllocations

var entered, finished: Event
var readCode = 0
var hostEvaluations = 0
proc hostName(): string =
  hostEvaluations += 1
  result = "localhost"
var retainedSource = default(SocketAddress)

proc pending(owner: sink UdpSocketRef; tok: nil CancelToken = nil) {.passive.} =
  var bytes = default(array[8, byte])
  setEvent(addr entered)
  readCode = recvFrom(owner, bytes, retainedSource, afterMs(2000), tok)
  setEvent(addr finished)

proc pendingBatch(owner: sink UdpSocketRef) {.passive.} =
  var batch = default(MmsgBatch)
  assert initBatch(batch, 2)
  setEvent(addr entered)
  readCode = recvBatch(owner, batch, afterMs(2000))
  freeBatch(batch)
  setEvent(addr finished)

proc main() {.passive.} =
  let baseline = liveCancelTokens()
  var raw = default(UdpSocket)
  raw.timeoutMs = 73
  raw.family = -1
  raw.error = "preserved"
  assert bindUdpInto(addr raw, 0, "127.0.0.1\0suffix") == InvalidInput
  assert not raw.ok and raw.timeoutMs == 73 and raw.family == -1 and raw.error == "preserved", "UDPRef check 23"
  let stopped = newCancelToken()
  cancel(stopped)
  assert connectUdpInto(addr raw, "127.0.0.1", 1234, tok=stopped) == ECancelled
  assert connectUdpInto(addr raw, "127.0.0.1", 1234, deadline=afterMs(0)) == IoTimedOut
  assert connectUdpInto(addr raw, "bad\0host", 1234) == InvalidInput
  assert connectUdpInto(addr raw, default(SocketAddress)) == InvalidInput, "UDPRef check 29"
  assert not raw.ok and raw.timeoutMs == 73 and raw.error == "preserved", "UDPRef check 30"
  release(stopped)
  assert bindUdpInto(addr raw, 0, "127.0.0.1", timeoutMs=0) == 0
  let fd = nativeHandle(raw)
  let target = localAddress(raw)
  assert openUdpInto(addr raw) == ResourceBusy, "UDPRef check 35"
  assert connectUdpInto(addr raw, target) == ResourceBusy, "UDPRef check 36"
  assert bindUdpInto(addr raw) == ResourceBusy, "UDPRef check 37"
  assert nativeHandle(raw) == fd and raw.timeoutMs == 0, "UDPRef check 38"
  var adoptedRaw = openUdp(timeoutMs=81)
  assert adoptedRaw.ok
  let socketFamily = adoptedRaw.family
  var detached = takeNativeHandle(addr adoptedRaw)
  assert not adoptedRaw.ok and detached >= 0
  assert not adoptUdp(addr raw, detached, socketFamily) and detached >= 0
  assert not adoptUdp(addr adoptedRaw, detached, -1) and detached >= 0
  assert adoptUdp(addr adoptedRaw, detached, socketFamily, timeoutMs=92)
  assert detached == -1 and adoptedRaw.ok and adoptedRaw.timeoutMs == 92
  close(adoptedRaw)
  var conflict = default(UdpSocket)
  conflict.error = "bind failure"
  assert bindUdpInto(addr conflict, target.port, "127.0.0.1") < 0
  assert not conflict.ok and conflict.error == "bind failure", "UDPRef check 42"
  let adopted = takeUdpSocketRef(raw)
  assert adopted.code == 0 and not raw.ok, "UDPRef check 54"
  let receiver = adopted.value
  if receiver != nil:
    assert nativeHandle(receiver) == fd and state(receiver) == ownerOpen, "UDPRef check 57"
    let connected = connectUdpRef("127.0.0.1", target.port, timeoutMs=0)
    let sender = connected.value
    if sender != nil:
      var bytes = [79'u8]
      var empty = default(array[0, byte])
      var source = default(SocketAddress)
      assert send(sender, empty, afterMs(2000)) == 0, "UDPRef check 65"
      assert recvFrom(receiver, empty, source, afterMs(2000)) == 0, "UDPRef check 66"
      assert source.port == localAddress(sender).port, "UDPRef check 67"
      # One zero-length receive consumes and discards one nonempty datagram.
      assert send(sender, bytes, afterMs(2000)) == 1, "UDPRef check 69"
      assert recvFrom(receiver, empty, source, afterMs(2000)) == 0, "UDPRef check 70"
      assert recvFrom(receiver, bytes, source, afterMs(10)) == IoTimedOut, "UDPRef check 71"
      when not defined(release):
        let allocationBaseline = cancelTokenAllocations()
      for cycle in 0..<128:
        let tokens = liveCancelTokens()
        assert send(sender, bytes, afterMs(2000)) == 1, "UDPRef check 74"
        assert recvFrom(receiver, bytes, source, afterMs(2000)) == 1 and bytes[0] == 79, "UDPRef check 75"
        assert sendTo(receiver, bytes, source, afterMs(2000)) == 1, "UDPRef check 76"
        assert recv(sender, bytes, afterMs(2000)) == 1 and bytes[0] == 79, "UDPRef check 77"
        assert liveCancelTokens() == tokens, "no per-datagram token allocation"
      when not defined(release):
        assert cancelTokenAllocations() == allocationBaseline, "no token allocation/free churn during 512 I/O operations"
        echo "UDP I/O token allocation calls: ", cancelTokenAllocations() - allocationBaseline
      let batchOpened = openUdpRef(timeoutMs=0)
      let batchSender = batchOpened.value
      if batchSender != nil:
        var outgoing = default(MmsgBatch)
        var incoming = default(MmsgBatch)
        assert initBatch(outgoing, 4) and initBatch(incoming, 4)
        # Batch headers preserve IPv4 fallback and mapped dual-stack targets.
        for i in 0..<3: setOutgoing(outgoing, i, i + 1, forFamily(target, family(batchSender)))
        let sent = sendBatch(batchSender, outgoing, 3, afterMs(2000))
        assert sent.sent == 3 and sent.error == 0
        var received = 0
        while received < 3:
          let count = recvBatch(receiver, incoming, afterMs(2000))
          assert count > 0
          for i in 0..<count:
            assert datagramLen(incoming, i) == received + i + 1
          received += count
        let noPackets = sendBatch(batchSender, outgoing, 0)
        assert noPackets.sent == 0 and noPackets.error == 0
        assert sendBatch(batchSender, outgoing, 5).error == InvalidInput
        assert sendBatch(batchSender, outgoing, 1, first = -1).error == InvalidInput
        assert sendBatch(batchSender, outgoing, 1, first = 4).error == InvalidInput
        assert sendBatch(batchSender, outgoing, high(int), first = 1).error == InvalidInput
        let cancelledSend = newCancelToken()
        cancel(cancelledSend)
        let stopped = sendBatch(batchSender, outgoing, 1, tok=cancelledSend)
        assert stopped.sent == 0 and stopped.error == ECancelled
        release(cancelledSend)
        # A valid first datagram followed by a missing destination forces
        # partial progress on native and fallback sendmmsg implementations.
        setOutgoing(outgoing, 0, 1, forFamily(target, family(batchSender)))
        setOutgoing(outgoing, 1, 1, default(SockAddrBuf))
        outgoing.slots[0].buf[0] = 71
        outgoing.slots[1].buf[0] = 72
        let partial = sendBatch(batchSender, outgoing, 2, afterMs(2000))
        assert partial.sent == 1 and partial.error < 0, "partial progress retains its error"
        assert recvBatch(receiver, incoming, afterMs(2000)) == 1
        assert datagramLen(incoming, 0) == 1 and incoming.slots[0].buf[0] == 71
        setOutgoing(outgoing, 1, 1, forFamily(target, family(batchSender)))
        let retried = sendBatch(batchSender, outgoing, 2 - partial.sent,
                                afterMs(2000), first=partial.sent)
        assert retried.sent == 1 and retried.error == 0
        assert recvBatch(receiver, incoming, afterMs(2000)) == 1
        assert datagramLen(incoming, 0) == 1 and incoming.slots[0].buf[0] == 72
        assert recvBatch(receiver, incoming, afterMs(20)) == IoTimedOut, "retry sends no duplicates"
        freeBatch(outgoing)
        freeBatch(incoming)
        assert close(batchSender) == 0
      else: assert false, "batch sender construction"
      let caller = newCancelToken()
      clearEvent(addr entered)
      clearEvent(addr finished)
      retainedSource = initSocketAddress(loopback4(), 9911)
      assert trySpawnTask(pending(receiver, caller)), "UDPRef check 83"
      assert wait(addr entered, afterMs(2000)) == wrReady, "UDPRef check 84"
      assert recvFrom(receiver, bytes, source) == ResourceBusy, "UDPRef check 85"
      # Opposite directions remain independently admitted while read waits.
      assert sendTo(receiver, bytes, localAddress(sender), afterMs(2000)) == 1, "UDPRef check 87"
      assert recv(sender, bytes, afterMs(2000)) == 1, "UDPRef check 88"
      cancel(caller)
      assert wait(addr finished, afterMs(2000)) == wrReady, "UDPRef check 90"
      assert readCode == ECancelled and retainedSource.port == 9911, "UDPRef check 91"
      assert state(receiver) == ownerOpen and nativeHandle(receiver) == fd, "UDPRef check 92"
      release(caller)
      assert send(sender, bytes, afterMs(2000)) == 1, "UDPRef check 94"
      assert recvFrom(receiver, bytes, source, afterMs(2000)) == 1, "UDPRef check 95"
      clearEvent(addr entered)
      clearEvent(addr finished)
      assert trySpawnTask(pendingBatch(receiver)), "UDPRef check 99"
      assert wait(addr entered, afterMs(2000)) == wrReady, "UDPRef check 100"
      let closed = close(receiver, afterMs(0))
      assert closed == 0 or closed == IoTimedOut
      assert state(receiver) != ownerOpen
      assert recvFrom(receiver, bytes, source) == ResourceClosed, "UDPRef check 103"
      assert sendTo(receiver, bytes, source) == ResourceClosed, "UDPRef check 104"
      assert close(receiver, afterMs(2000)) == 0, "UDPRef check 105"
      assert wait(addr finished, afterMs(2000)) == wrReady, "UDPRef check 106"
      assert readCode == ResourceClosed and state(receiver) == ownerClosed, "UDPRef check 107"
      assert nativeHandle(receiver) == -1 and close(receiver) == 0, "UDPRef check 108"
      # The freed slot is reused. Repeated close cannot touch the replacement.
      var replacement = bindUdp(0, "127.0.0.1")
      assert replacement.ok, "UDPRef check 111"
      echo "UDP replacement descriptor reused: ", nativeHandle(replacement) == fd
      assert close(receiver) == 0, "UDPRef check 113"
      let destination = localAddress(replacement)
      let opened = openUdpRef(timeoutMs=0)
      let probe = opened.value
      if probe != nil:
        assert sendTo(probe, bytes, destination, afterMs(2000)) == 1, "replacement send from unconnected socket"
        assert recvFrom(replacement, bytes, source, afterMs(2000)) == 1, "replacement receive"
        assert close(probe) == 0
      else: assert false, "replacement probe"
      close(replacement)
      assert close(sender) == 0 and close(sender) == 0, "UDPRef check 118"
    else: assert false, "friendly UDP association"
  else: assert false, "friendly UDP transfer"
  # Scope exit leaves a queued task as the sole Ref owner across its read park.
  var transmitter = openUdp()
  assert transmitter.ok, "UDPRef check 123"
  var bytes = [1'u8]
  for cycle in 0..<64:
    clearEvent(addr entered)
    clearEvent(addr finished)
    var destination = default(SocketAddress)
    block:
      let opened = bindUdpRef(0, "127.0.0.1", timeoutMs=0)
      let owner = opened.value
      if owner != nil:
        destination = localAddress(owner)
        assert trySpawnTask(pending(owner)), "UDPRef check 134"
      else: assert false, "queued final owner"
    assert wait(addr entered, afterMs(2000)) == wrReady, "UDPRef check 136"
    assert sendTo(transmitter, bytes, destination, afterMs(2000)) == 1, "UDPRef check 137"
    assert wait(addr finished, afterMs(2000)) == wrReady and readCode == 1, "UDPRef check 138"
    yieldNow()
  close(transmitter)
  let resolved = connectUdpRef(hostName(), 1234, deadline=afterMs(2000))
  assert resolved.code == 0 and hostEvaluations == 1
  let namedOwner = resolved.value
  if namedOwner != nil: assert close(namedOwner) == 0
  else: assert false, "hostname UDP association"
  let constructorStop = newCancelToken()
  cancel(constructorStop)
  let cancelledConstruction = connectUdpRef("localhost", 1234, tok=constructorStop)
  assert cancelledConstruction.code == ECancelled and cancelledConstruction.value == nil
  release(constructorStop)
  let bad = bindUdpRef(0, "bad\0bind")
  assert bad.code == InvalidInput and bad.value == nil, "UDPRef check 142"
  let invalid = connectUdpRef(default(SocketAddress))
  assert invalid.code == InvalidInput and invalid.value == nil, "UDPRef check 144"
  echo "PASS friendly UDP transfer, admission, cancellation, drained close and final owner"
  close(raw)
  close(raw)
  stopBlockingPool()
  while not joinBlockingPool(): parkUntil(afterMs(1))
  let until = afterMs(2000)
  while liveCancelTokens() != baseline and monoNow() < until: parkUntil(afterMs(1))
  assert liveCancelTokens() == baseline, "UDPRef check 152"
  assert liveBlockingJobs() == 0, "UDPRef check 153"
  requestStop()
  assert openUdpInto(addr raw) == ResourceClosed, "UDPRef check 155"
  assert bindUdpInto(addr raw) == ResourceClosed, "UDPRef check 156"
assert runMain(main()), "UDPRef check 159"
