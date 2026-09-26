## Raw IP: where the process may (root / CAP_NET_RAW), a raw ICMP socket
## sends an echo request to 127.0.0.1 and reads the reply with its IP
## header (TTL taken from it); the unprivileged ICMP datagram socket does
## the same without privileges.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/net/address
import zal_net/raw/ip

proc echoRequest(buf: var array[64, byte]; id, sq: uint16) =
  buf[0] = 8
  buf[4] = byte(id shr 8)
  buf[5] = byte(id and 0xff)
  buf[6] = byte(sq shr 8)
  buf[7] = byte(sq and 0xff)
  var sum = 0'u32
  var i = 0
  while i < 16:
    sum = sum + (uint32(buf[i]) shl 8) + uint32(buf[i + 1])
    i = i + 2
  while (sum shr 16) != 0: sum = (sum and 0xffff) + (sum shr 16)
  let c = not uint16(sum)
  buf[2] = byte(c shr 8)
  buf[3] = byte(c and 0xff)

proc roundTrip(s: IpSocket): bool {.passive.} =
  var req = default(array[64, byte])
  echoRequest(req, 0x4242, 7)
  assert sendTo(s, addr req[0], 16, loopback4()) == 16
  var buf = default(array[256, byte])
  var info = default(IpRecvInfo)
  while true:
    let n = recvFrom(s, addr buf[0], buf.len, addr info, afterMs(2000))
    if n <= 0: return false
    let off = info.headerLen
    if n - off >= 8 and buf[off] == 0 and buf[off + 7] == 7:   # echo reply, our sequence
      return $info.source == "127.0.0.1"

proc main() {.passive.} =
  var raw = openIp(ipIcmp)
  if raw.ok:
    assert roundTrip(raw)
    close(raw)
    echo "PASS a raw ICMP socket: echo request and reply with its IP header"
  else:
    echo "SKIP raw sockets need privileges here (", raw.error, ")"
  var dg = openIp(ipIcmp, datagram = true)
  if dg.ok:
    assert roundTrip(dg)
    close(dg)
    echo "PASS the unprivileged ICMP datagram socket"
  else:
    echo "SKIP ICMP datagram sockets are not allowed here"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
