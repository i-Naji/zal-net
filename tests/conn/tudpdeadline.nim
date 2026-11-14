## UdpSocket edges: an expired deadline sends nothing and takes nothing, an
## empty buffer still takes a datagram, arguments are evaluated once, ready
## traffic leaves room for another task and makes no tokens, an oversized
## datagram and a bad host raise, and a second close is fine.
import std/[assertions, syncio]
import zal_net/rt
import zal_net/rt/sync
import zal_net/udp
import zal_net/net/address

type Shared = ref object
  done: Event

proc observer(shared: Shared) {.passive.} = setEvent(addr shared.done)

proc payload(calls: var int): array[3, byte] =
  inc calls
  [11'u8, 22, 33]

template timesOut(body: untyped) =
  block:
    var got = Success
    try:
      body
    except ErrorCode as error:
      got = error
    assert got == TimeoutError, "expected TimeoutError, got " & $got

proc main() {.passive.} =
  try:
    var receiver = openUdp(0, "127.0.0.1")
    var sender = openUdp(0, "127.0.0.1")
    var unconnected = openUdp(0, "127.0.0.1")
    sender.connect(receiver.localAddress)
    let target = receiver.localAddress
    let expired = afterMs(-1)
    var buffer = [99'u8, 98, 97]
    var empty = default(array[0, byte])
    var source = default(SocketAddress)

    # Expired sends leave no datagram behind.
    timesOut: sender.send([1'u8], expired)
    timesOut: sender.send(empty, expired)
    timesOut: unconnected.sendTo([2'u8], target, expired)
    timesOut: discard receiver.recvFrom(buffer, source, afterMs(20))

    # An expired receive leaves a queued datagram and the caller's bytes alone.
    sender.send([42'u8], afterMs(2000))
    timesOut: discard receiver.recvFrom(buffer, source, expired)
    timesOut: discard receiver.recvFrom(empty, source, expired)
    assert buffer[0] == 99 and source.port == 0
    assert receiver.recvFrom(buffer, source, afterMs(2000)) == 1 and buffer[0] == 42
    assert source.port == sender.port
    receiver.sendTo([43'u8], source, afterMs(2000))
    timesOut: discard sender.recv(buffer, expired)
    assert sender.recv(buffer, afterMs(2000)) == 1 and buffer[0] == 43

    # A receive into an empty buffer takes one datagram whole.
    sender.send([1'u8, 2, 3], afterMs(2000))
    assert receiver.recvFrom(empty, source, afterMs(2000)) == 0
    sender.send([9'u8], afterMs(2000))
    assert receiver.recvFrom(buffer, source, afterMs(2000)) == 1 and buffer[0] == 9

    # The data argument is evaluated once.
    var calls = 0
    receiver.sendTo(payload(calls), sender.localAddress, afterMs(2000))
    assert calls == 1
    assert sender.recv(buffer, afterMs(2000)) == 3 and buffer[2] == 33

    # Ready traffic in a loop leaves room for another task and makes no token.
    let tokens = liveCancelTokens()
    let shared = Shared()
    assert trySpawnTask(observer(shared))
    for i in 0 ..< 1024:
      sender.send([45'u8], afterMs(2000))
      assert receiver.recvFrom(buffer, source, afterMs(2000)) == 1
    assert wait(addr shared.done, afterMs(1000)) == wrReady
    assert liveCancelTokens() == tokens, "a datagram makes no token"

    # Too big for one datagram, and a host with a NUL in it.
    var raised = Success
    try: sender.send(newSeq[byte](70_000), afterMs(2000))
    except ErrorCode as error: raised = error
    assert raised == ContentTooLong, "oversized: " & $raised
    raised = Success
    try:
      var bad = openUdp(0, "127.0.0.1\0suffix")
      close bad
    except ErrorCode as error: raised = error
    assert raised == ValueError, "bad host: " & $raised

    close receiver
    close receiver
    assert not receiver.isOpen
    close sender
    close unconnected
    echo "PASS UDP expired deadlines keep datagrams, empty buffers, one evaluation, fairness, bad input"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
