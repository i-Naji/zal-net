## TUN: where the process may (root / CAP_NET_ADMIN), a new device gets
## 10.99.0.1 with peer 10.99.0.2; a UDP datagram sent to the peer comes
## out of the device as an IPv4 packet, and a packet written back into the
## device (addresses and ports swapped) reaches the UDP socket.
import std/assertions
import std/syncio
import zal_net/errors
import zal_net/rt
import zal_net/raw/io
import zal_net/net/address
import zal_net/raw/udp
import zal_net/net/interfaces
import zal_net/raw/tun

proc sum16(b: ptr UncheckedArray[byte]; n: int): uint16 =
  var s = 0'u32
  var i = 0
  while i + 1 < n:
    s = s + (uint32(b[i]) shl 8) + uint32(b[i + 1])
    i = i + 2
  while (s shr 16) != 0: s = (s and 0xffff) + (s shr 16)
  result = not uint16(s)

proc swapAt(b: var array[2048, byte]; i, j: int) =
  let t = b[i]
  b[i] = b[j]
  b[j] = t

proc main() {.passive.} =
  var empty = default(TunDevice)
  var byteBuf = 0'u8
  assert recvInto(empty, addr byteBuf, -1) == InvalidInput
  assert sendFrom(empty, addr byteBuf, -1) == InvalidInput
  assert recvInto(empty, addr byteBuf, 0) == 0
  assert sendFrom(empty, addr byteBuf, 0) == 0
  assert recvInto(empty, addr byteBuf, 1) == ResourceClosed
  assert sendFrom(empty, addr byteBuf, 1) == ResourceClosed
  close(empty)
  close(empty)
  echo "PASS empty TUN ownership and transfer bounds"
  var t = openTun()
  if not t.ok:
    echo "SKIP TUN devices need privileges here (", t.error, ")"
    quit 0
  let local = ipv4(10, 99, 0, 1)
  let peer = ipv4(10, 99, 0, 2)
  assert addAddress4(t.name, local, 32, peer)
  assert setInterfaceUp(t.name)
  let ni = interfaceByName(t.name)
  assert ni.index != 0 and isUp(ni)

  var u = bindUdp(initSocketAddress(local, 0))
  assert u.error.len == 0
  var payload = [byte 104, 101, 108, 108, 111, 32, 116, 117, 110]   # "hello tun"
  assert sendTo(u, addr payload[0], payload.len, initSocketAddress(peer, 9)) == payload.len

  var pkt = default(array[2048, byte])
  var n = 0
  var hl = 0
  while true:                       # skip the system's own traffic (router solicitations, NetBIOS...)
    n = recvInto(t, addr pkt[0], pkt.len, afterMs(3000))
    assert n > 0
    hl = int(pkt[0] and 0x0f) * 4
    if (pkt[0] shr 4) == 4 and pkt[9] == 17 and pkt[hl + 2] == 0 and pkt[hl + 3] == 9: break
  assert pkt[16] == 10 and pkt[17] == 99 and pkt[18] == 0 and pkt[19] == 2
  assert pkt[hl + 2] == 0 and pkt[hl + 3] == 9
  assert n - hl - 8 == payload.len
  echo "PASS a UDP datagram to the peer came out of ", t.name, " (", n, " bytes)"

  # Swap addresses and ports, clear the UDP checksum, fix the IP checksum.
  var i = 0
  while i < 4:
    swapAt(pkt, 12 + i, 16 + i)
    i = i + 1
  swapAt(pkt, hl, hl + 2)
  swapAt(pkt, hl + 1, hl + 3)
  pkt[hl + 6] = 0
  pkt[hl + 7] = 0
  pkt[10] = 0
  pkt[11] = 0
  let c = sum16(cast[ptr UncheckedArray[byte]](addr pkt[0]), hl)
  pkt[10] = byte(c shr 8)
  pkt[11] = byte(c and 0xff)
  assert sendFrom(t, addr pkt[0], n) == n

  var got = default(array[64, byte])
  var src = default(SocketAddress)
  let k = recvFrom(u, addr got[0], got.len, addr src, afterMs(3000))
  assert k == payload.len and port(src) == 9 and $ip(src) == "10.99.0.2"
  echo "PASS a packet written into the device reached the UDP socket"
  close(u)
  close(t)
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
