## UDP: echo over IPv4 (an IPv4 destination on a dual-stack socket) and
## IPv6; a receive that times out; a connected socket; 32 datagrams each
## way in batches.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/rt/sync
import zal_net/raw/io
import zal_net/net/sockaddr
import zal_net/raw/mmsg
import zal_net/net/address
import zal_net/raw/udp

var turns = 0
var done: Event
var bufferCalls, lengthCalls, addressCalls = 0
proc datagramBuffer(p: pointer): pointer =
  inc bufferCalls
  result = p
proc datagramLength(n: int): int =
  inc lengthCalls
  result = n
proc datagramAddress(address: SocketAddress): SocketAddress =
  inc addressCalls
  result = address
proc observer() {.passive.} =
  inc turns
  setEvent(addr done)

proc echoServer(u: UdpSocket; count: int) {.passive.} =
  var buf = default(array[2048, byte])
  var k = 0
  while k < count:
    var src = default(SocketAddress)
    let n = recvFrom(u, buf, src)
    if n < 0: break
    discard sendTo(u, buf.toOpenArray(0, n - 1), src)
    k = k + 1

proc batchServer(u: UdpSocket; count: int) {.passive.} =
  var b = default(MmsgBatch)
  var o = default(MmsgBatch)
  assert initBatch(b, 16) and initBatch(o, 16)
  var got = 0
  while got < count:
    let n = recvBatch(u, addr b)
    if n <= 0: break
    var i = 0
    while i < n:
      let len = datagramLen(b, i)
      copyMem(addr o.slots[i].buf[0], addr b.slots[i].buf[0], len)
      var peer = default(SockAddrBuf)
      copyMem(addr peer.ss, addr b.slots[i].name, int(peerLen(b, i)))
      peer.len = peerLen(b, i)
      setOutgoing(o, i, len, peer)
      i = i + 1
    discard sendBatch(u, addr o, n)
    got = got + n
  freeBatch(b)
  freeBatch(o)

proc sa(text: string): SocketAddress =
  result = default(SocketAddress)
  assert parseSocketAddress(text, result)

proc main() {.passive.} =
  let msg = [byte 1, 2, 3, 4, 5]
  var buf = default(array[64, byte])
  var bytes = [1'u8]
  var udpReceiver = bindUdp(0, "127.0.0.1")
  var udpSender = bindUdp(0, "127.0.0.1")
  assert udpReceiver.ok and udpSender.ok
  let destination = localAddress(udpReceiver)
  var source = default(SocketAddress)
  clearEvent(addr done)
  turns = 0
  assert trySpawnTask(observer())
  for i in 0 ..< 128:
    assert sendTo(udpSender, datagramBuffer(addr bytes[0]),
      datagramLength(bytes.len), datagramAddress(destination), afterMs(2000)) == 1
    assert recvFrom(udpReceiver, addr bytes[0], bytes.len,
      addr source, afterMs(2000)) == 1
  assert isSet(addr done), "ready UDP yields before another wait can schedule the observer"
  assert turns == 1 and bufferCalls == 128 and lengthCalls == 128 and addressCalls == 128,
    "scalar UDP arguments are captured once across the I/O budget yield"
  close(udpSender)
  close(udpReceiver)
  echo "PASS ready UDP fairness and single argument evaluation"

  let s4 = bindUdp(0, "127.0.0.1")
  assert s4.ok, s4.error
  spawnTask echoServer(s4, 1)
  var c = openUdp()                       # dual stack
  assert sendTo(c, msg, sa("127.0.0.1:" & $port(localAddress(s4)))) == 5
  var src = default(SocketAddress)
  assert recvFrom(c, buf, src) == 5 and $src == "127.0.0.1:" & $port(localAddress(s4))
  echo "PASS UDP echo to an IPv4 address from a dual-stack socket"

  let s6 = bindUdp(0, "::1")
  spawnTask echoServer(s6, 1)
  assert sendTo(c, msg, sa("[::1]:" & $port(localAddress(s6)))) == 5
  assert recvFrom(c, buf, src) == 5
  echo "PASS UDP echo over IPv6"

  var quiet = bindUdp(0, "127.0.0.1", timeoutMs = 200)
  let t0 = monoNow()
  assert recvFrom(quiet, buf, src) == IoTimedOut
  assert (int64(monoNow()) - int64(t0)) div 1_000_000 >= 150
  close(quiet)
  echo "PASS a receive times out"

  let s3 = bindUdp(0, "127.0.0.1")
  spawnTask echoServer(s3, 1)
  var cc = connectUdp("127.0.0.1", port(localAddress(s3)))
  assert cc.ok and send(cc, msg) == 5 and recv(cc, buf) == 5
  close(cc)
  echo "PASS a connected UDP socket"

  let sb = bindUdp(0, "127.0.0.1")
  spawnTask batchServer(sb, 32)
  var cb = bindUdp(0, "127.0.0.1")
  let to = localAddress(sb)
  var k = 0
  while k < 32:
    assert sendTo(cb, msg, to) == 5
    k = k + 1
  var seen = 0
  while seen < 32 and recvFrom(cb, buf, src) == 5: seen = seen + 1
  assert seen == 32
  echo "PASS 32 datagrams each way through recvBatch/sendBatch"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
