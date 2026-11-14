import zal_net/codecs/socksaddr
import zal_net/net/endpointdial
## Endpoints and the SOCKS address codec: parse, encode, views, socket
## addresses, host:port text, and malformed input.
import std/assertions
import std/syncio
import zal_net/bytes
import zal_net/net/endpoint
import zal_net/net/sockaddr

proc roundTrip(d: Endpoint) =
  var buf = default(array[300, byte])
  let n = encodeSocksAddr(d, buf, 5)
  assert n == socksAddrLen(d) and n > 0
  var back = default(Endpoint)
  assert parseSocksAddr(buf.toOpenArray(5, 5 + n - 1), back) == n
  assert back.kind == d.kind and back.port == d.port
  assert formatEndpoint(back) == formatEndpoint(d)

proc main() =
  var d = default(Endpoint)
  # Kage's parseDest cases.
  assert parseSocksAddr(@[1'u8], d) < 0 and not valid(d)
  assert parseSocksAddr(@[3'u8, 0, 0, 80], d) < 0          # empty name
  assert parseSocksAddr(@[3'u8, 1, 0, 0, 80], d) < 0       # NUL in the name
  assert parseSocksAddr(@[7'u8, 1, 2, 3, 4, 0, 80], d) < 0 # unknown atyp
  assert parseSocksAddr(@[1'u8, 1, 2, 3, 4, 0], d) < 0     # short port
  assert parseSocksAddr(newSeq[byte](0), d) < 0
  assert parseSocksAddr(@[1'u8, 10, 0, 0, 1, 0x1f, 0x90, 99], d) == 7
  assert d.kind == epIp4 and d.port == 8080'u16 and formatEndpoint(d) == "10.0.0.1:8080"
  let name = "example.com"
  var raw = @[3'u8, byte(name.len)]
  for c in name: raw.add byte(c)
  raw.add 0'u8
  raw.add 80'u8
  assert parseSocksAddr(raw, d) == raw.len
  assert d.kind == epName and hostString(d) == "example.com" and d.port == 80'u16
  echo "PASS parse"

  # Round trips.
  var a = default(Endpoint)
  assert setIp(a, [192'u8, 168, 1, 2], 443'u16)
  roundTrip(a)
  var ip6 = default(array[16, byte])
  ip6[15] = 1
  assert setIp(a, ip6, 53'u16)
  roundTrip(a)
  assert formatEndpoint(a) == "[0000:0000:0000:0000:0000:0000:0000:0001]:53"
  var long = newString(255)
  for i in 0 ..< 255: long[i] = 'a'
  assert setName(a, long, 1'u16)
  roundTrip(a)
  assert not setName(a, long & "a", 1'u16)
  var tooSmall = default(array[8, byte])
  assert encodeSocksAddr(a, tooSmall, 0) == 0
  echo "PASS encode round trips"

  # A view does not copy; limits are respected.
  var buf = @[0'u8, 0, 3, 3, byte('a'), byte('b'), byte('c'), 1, 187]
  let p = cast[ptr UncheckedArray[byte]](addr buf[0])
  var v = default(SocksAddrView)
  assert viewSocksAddr(p, 2, buf.len, v)
  assert v.kind == epName and v.off == 4 and v.len == 3 and v.port == 443'u16 and v.used == 7
  assert not viewSocksAddr(p, 2, buf.len - 1, v)
  echo "PASS view"

  # Socket addresses, including IPv4-mapped IPv6.
  var sa = default(SockAddrBuf)
  assert setIp(a, [127'u8, 0, 0, 1], 9000'u16)
  assert endpointSockAddr(a, AF_INET6, sa)             # mapped
  var outp = default(array[32, byte])
  let op = cast[ptr UncheckedArray[byte]](addr outp[0])
  assert sockToSocksAddr(sa.ss, sa.len, op, 1) == 7
  assert outp[1] == AtypIp4 and outp[2] == 127 and beU16(op, 6) == 9000'u16
  assert endpointSockAddr(a, AF_INET, sa)
  assert sockToSocksAddr(sa.ss, sa.len, op, 0) == 7
  assert setIp(a, ip6, 8'u16) and endpointSockAddr(a, AF_INET6, sa)
  assert sockToSocksAddr(sa.ss, sa.len, op, 0) == 19 and outp[0] == AtypIp6
  var dom = default(Endpoint)
  assert setName(dom, "x.y", 1'u16) and not endpointSockAddr(dom, 0.cint, sa)
  echo "PASS socket addresses"

  # host:port text.
  assert parseHostPort("1.2.3.4:80", d) and d.kind == epIp4 and d.port == 80'u16
  assert parseHostPort("[::1]:8388", d) and d.kind == epIp6 and d.ip[15] == 1
  assert parseHostPort("exit.example:8388", d) and d.kind == epName and hostString(d) == "exit.example"
  assert parseHostPort("localhost:0", d) and d.port == 0'u16
  assert not parseHostPort("::1:80", d)
  assert not parseHostPort("host:", d)
  assert not parseHostPort("host:65536", d)
  assert not parseHostPort(":80", d)
  assert not parseHostPort("[::1:80", d)
  assert not parseHostPort("host:8a", d)
  echo "PASS host:port"

  # Byte helpers.
  var b = default(array[16, byte])
  putU64be(b, 0, 0x0102030405060708'u64)
  putU16be(b, 8, 0xABCD'u16)
  assert u64be(b, 0) == 0x0102030405060708'u64 and u16be(b, 8) == 0xABCD'u16
  let bp = cast[ptr UncheckedArray[byte]](addr b[0])
  putBeU64(bp, 8, 42'u64)
  assert beU64(bp, 8) == 42'u64
  var x = [1'u8, 2, 3]
  var y = [1'u8, 2, 3]
  assert sameBytes(addr x[0], addr y[0], 3)
  y[2] = 4
  assert not sameBytes(addr x[0], addr y[0], 3)
  echo "PASS bytes"

main()
