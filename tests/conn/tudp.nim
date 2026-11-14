import std/[assertions, syncio]
import zal_net/rt
import zal_net/rt/[sync, cancel]
import zal_net/udp
import zal_net/net/address

type Shared = ref object
  done: Event
  outcome: ErrorCode

proc parked(u: ptr UdpSocket; shared: Shared) {.passive.} =
  var buffer = default(array[16, byte])
  var peer = default(SocketAddress)
  try:
    discard u[].recvFrom(buffer, peer, afterMs(5000))
    shared.outcome = Success
  except ErrorCode as error:
    shared.outcome = error
  setEvent(addr shared.done)

proc main() {.passive.} =
  try:
    # Echo between two sockets on IPv4 loopback.
    var server = openUdp(0, "127.0.0.1")
    var client = openUdp(0, "127.0.0.1")
    let serverAddress = server.localAddress
    var buffer = default(array[64, byte])
    var peer = default(SocketAddress)
    client.sendTo([1'u8, 2, 3], serverAddress, afterMs(5000))
    let n = server.recvFrom(buffer, peer, afterMs(5000))
    assert n == 3 and buffer[0] == 1 and buffer[2] == 3
    assert peer.port == client.port
    server.sendTo(buffer.toOpenArray(0, n - 1), peer, afterMs(5000))
    buffer[0] = 0
    assert client.recvFrom(buffer, peer, afterMs(5000)) == 3 and buffer[0] == 1
    assert peer.port == server.port

    # An empty datagram is a message, and a short buffer keeps the head.
    var empty = default(array[0, byte])
    client.sendTo(empty, serverAddress, afterMs(5000))
    assert server.recvFrom(buffer, peer, afterMs(5000)) == 0
    var two = default(array[2, byte])
    client.sendTo([4'u8, 5, 6, 7], serverAddress, afterMs(5000))
    assert server.recvFrom(two, peer, afterMs(5000)) == 2 and two == [4'u8, 5]

    # A socket on every address hears IPv4 peers and answers them.
    var wide = openUdp()
    client.sendTo([8'u8], initSocketAddress(loopback4(), wide.port), afterMs(5000))
    assert wide.recvFrom(buffer, peer, afterMs(5000)) == 1 and buffer[0] == 8
    assert peer.ip == loopback4() and peer.port == client.port
    wide.sendTo([9'u8], peer, afterMs(5000))
    assert client.recvFrom(buffer, peer, afterMs(5000)) == 1 and buffer[0] == 9
    close wide

    # A connected pair: one by name, one by address.
    var left = openUdp(0, "127.0.0.1")
    var right = openUdp(0, "127.0.0.1")
    left.connect("127.0.0.1", right.port, afterMs(5000))
    right.connect(left.localAddress)
    assert left.remoteAddress.port == right.port
    assert right.remoteAddress.port == left.port
    left.send([10'u8, 11], afterMs(5000))
    assert right.recv(buffer, afterMs(5000)) == 2 and buffer[1] == 11
    right.send([12'u8], afterMs(5000))
    assert left.recv(buffer, afterMs(5000)) == 1 and buffer[0] == 12

    # A deadline that passes raises; the socket stays usable.
    var timedOut = false
    try: discard right.recv(buffer, afterMs(30))
    except ErrorCode as error: timedOut = error == TimeoutError
    assert timedOut
    right.renew afterMs(20)
    timedOut = false
    try: discard right.recv(buffer)
    except ErrorCode as error: timedOut = error == TimeoutError
    assert timedOut
    right.renew never
    left.send([13'u8])
    assert right.recv(buffer) == 1 and buffer[0] == 13

    # Cancelling the owner's token ends a parked receive.
    let stop = newCancelToken()
    var watched = openUdp(0, "127.0.0.1", stop)
    let shared = Shared(outcome: Success)
    assert trySpawnTask(parked(addr watched, shared))
    parkUntil(afterMs(50))
    cancel(stop)
    assert wait(addr shared.done, afterMs(5000)) == wrReady
    assert shared.outcome == AbortedOperation
    assert watched.cancelToken.cancelled
    var refused = false
    try: watched.sendTo([14'u8], serverAddress)
    except ErrorCode as error: refused = error == AbortedOperation
    assert refused
    close watched
    release(stop)

    # A move hands the descriptor over; the moved-from value closes nothing.
    var original = openUdp(0, "127.0.0.1")
    let handle = original.nativeHandle
    block:
      var moved = move(original)
      assert not original.isOpen and moved.isOpen and moved.nativeHandle == handle
      moved.sendTo([15'u8], serverAddress, afterMs(5000))
      assert server.recvFrom(buffer, peer, afterMs(5000)) == 1 and buffer[0] == 15
    # `moved` closed the descriptor; `fresh` may get the same number back.
    var fresh = openUdp(0, "127.0.0.1")
    close original
    fresh.sendTo([16'u8], serverAddress, afterMs(5000))
    assert server.recvFrom(buffer, peer, afterMs(5000)) == 1 and buffer[0] == 16
    assert peer.port == fresh.port
    close fresh
    close fresh
    assert not fresh.isOpen

    close left
    close right
    close client
    close server
    echo "PASS UDP echo, dual stack, a connected pair, a timeout, a cancelled receive and a move"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
