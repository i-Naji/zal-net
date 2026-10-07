{.feature: "assumeSync".}
## Friendly ancillary I/O shares raw metadata and owner cancellation machinery.
import std/[assertions, syncio]
import zal_net/[rt, errors], zal_net/rt/[sync, cancel]
import zal_net/raw/udp, zal_net/foundation/udp, zal_net/net/address
when not defined(release):
  from zal_net/private/core/cancelstate import cancelTokenAllocations

var entered, finished: Event
var resultCode: int
var retainedInfo: DatagramInfo
proc pending(owner: sink UdpSocketRef; tok: nil CancelToken = nil) {.passive.} =
  var bytes = default(array[8, byte])
  setEvent(addr entered)
  resultCode = recvFrom(owner, bytes, retainedInfo, afterMs(2000), tok)
  setEvent(addr finished)

proc main() {.passive.} =
  let baseline = liveCancelTokens()
  let receiving = bindUdpRef(0, "127.0.0.1", timeoutMs=0)
  let sending = bindUdpRef(0, "127.0.0.1", timeoutMs=0)
  let receiver = receiving.value
  let sender = sending.value
  assert receiver != nil and sender != nil
  if receiver != nil and sender != nil:
    assert enableInfo(receiver)
    assert setBroadcast(sender) and setBroadcast(sender, false)
    assert setMulticastTtl(sender, 1) and setMulticastLoop(sender, true)
    assert not setMulticastTtl(sender, -1) and not setMulticastTtl(sender, high(int))
    let target = localAddress(receiver)
    var message = [7'u8, 8, 9]
    var bytes = default(array[8, byte])
    var info = default(DatagramInfo)
    var source = default(SocketAddress)
    when not defined(release):
      let calls = cancelTokenAllocations()
    for iteration in 0..<128:
      assert sendTo(sender, message, target, afterMs(2000)) == 3
      assert recvFrom(receiver, bytes, info, afterMs(2000)) == 3
      assert bytes[0] == 7 and bytes[2] == 9
      assert info.source.port == localAddress(sender).port
      assert info.hasDestination and info.destination == loopback4()
      assert info.interfaceIndex > 0 and info.ttl > 0 and not info.truncated
      assert sendWithSource(receiver, message, info.source, info.destination,
                            deadline=afterMs(2000)) == 3
      assert recvFrom(sender, bytes, source, afterMs(2000)) == 3
      assert ip(source) == loopback4() and source.port == target.port
    when not defined(release):
      assert cancelTokenAllocations() == calls, "metadata operations allocate no child tokens"
    var small = default(array[1, byte])
    assert sendTo(sender, message, target, afterMs(2000)) == 3
    assert recvFrom(receiver, small, info, afterMs(2000)) == 1 and info.truncated
    var empty = default(array[0, byte])
    assert sendWithSource(sender, empty, target, loopback4(), deadline=afterMs(2000)) == 0
    assert recvFrom(receiver, empty, info, afterMs(2000)) == 0 and not info.truncated
    assert sendTo(sender, message, target, afterMs(2000)) == 3
    assert recvFrom(receiver, empty, info, afterMs(2000)) == 0 and info.truncated
    assert recvFrom(receiver, bytes, info, afterMs(10)) == IoTimedOut
    let tok = newCancelToken()
    retainedInfo.ttl = 771
    assert trySpawnTask(pending(receiver, tok))
    assert wait(addr entered, afterMs(2000)) == wrReady
    assert not enableInfo(receiver), "settings reject a pending borrower"
    assert recvFrom(receiver, bytes, info) == ResourceBusy
    cancel(tok)
    assert wait(addr finished, afterMs(2000)) == wrReady and resultCode == ECancelled
    assert retainedInfo.ttl == 771, "failed receive preserves metadata"
    release(tok)
    clearEvent(addr entered)
    clearEvent(addr finished)
    assert trySpawnTask(pending(receiver))
    assert wait(addr entered, afterMs(2000)) == wrReady
    let closed = close(receiver, afterMs(0))
    assert closed == 0 or closed == IoTimedOut
    assert not enableInfo(receiver) and not setBroadcast(receiver)
    assert close(receiver, afterMs(2000)) == 0
    assert wait(addr finished, afterMs(2000)) == wrReady and resultCode == ResourceClosed
    assert recvFrom(receiver, bytes, info) == ResourceClosed
    assert sendWithSource(receiver, message, target, loopback4()) == ResourceClosed
    assert close(sender) == 0
  echo "PASS friendly UDP metadata, selected source, truncation, cancellation and close drain"
  assert liveCancelTokens() == baseline

assert runMain(main())
