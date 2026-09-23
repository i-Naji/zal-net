## Addresses: IP addresses, socket addresses (an IP address and a port, or
## a Unix-domain path) and CIDR networks; parsing, formatting, comparison
## and name resolution. `SocketAddress` holds the system's own form (plain
## data, no allocation), so it goes to `connect`, `bind` or `sendTo` as is.
##
## ```nim
## var a = default(SocketAddress)
## if parseSocketAddress("[::1]:8080", a): echo a, " port ", a.port
## for x in resolve("example.org", 443): echo x
## ```

import std/syncio
import zal_net/net/sockaddr
from zal_net/buffers import bytesPtr

type
  IpFamily* = enum
    ipv4, ipv6

  IpAddress* = object
    family*: IpFamily
    bytes*: array[16, byte]       ## IPv4 uses the first four

  SocketAddress* = object
    ## An IP address and port, or a Unix-domain path, in the system's form.
    raw*: SockAddrBuf

  Cidr* = object
    ## A network: an address and a prefix length.
    ip*: IpAddress
    bits*: int


const AfUnix = 1.cint

# ------------------------------------------------------------ IP addresses

proc ipv4*(a, b, c, d: byte): IpAddress =
  result = IpAddress(family: ipv4)
  result.bytes[0] = a
  result.bytes[1] = b
  result.bytes[2] = c
  result.bytes[3] = d

proc loopback4*(): IpAddress = ipv4(127, 0, 0, 1)
proc any4*(): IpAddress = IpAddress(family: ipv4)
proc any6*(): IpAddress = IpAddress(family: ipv6)

proc loopback6*(): IpAddress =
  result = IpAddress(family: ipv6)
  result.bytes[15] = 1

proc ipLen*(ip: IpAddress): int {.inline.} = (if ip.family == ipv4: 4 else: 16)

proc isMapped4*(ip: IpAddress): bool =
  ## ::ffff:a.b.c.d, how a dual-stack socket reports IPv4 peers.
  if ip.family != ipv6 or ip.bytes[10] != 0xff or ip.bytes[11] != 0xff: return false
  var i = 0
  while i < 10:
    if ip.bytes[i] != 0: return false
    i = i + 1
  result = true

proc unmapped*(ip: IpAddress): IpAddress =
  ## An IPv4-mapped IPv6 address as IPv4; others unchanged.
  if isMapped4(ip): ipv4(ip.bytes[12], ip.bytes[13], ip.bytes[14], ip.bytes[15]) else: ip

proc isUnspecified*(ip: IpAddress): bool =
  result = true
  var i = 0
  while i < ipLen(ip):
    if ip.bytes[i] != 0: return false
    i = i + 1

proc isLoopback*(ip: IpAddress): bool =
  let u = unmapped(ip)
  if u.family == ipv4: return u.bytes[0] == 127
  result = u == loopback6()

proc `==`*(a, b: IpAddress): bool =
  if a.family != b.family: return false
  var i = 0
  while i < ipLen(a):
    if a.bytes[i] != b.bytes[i]: return false
    i = i + 1
  result = true

proc parseIp*(s: string; ip: var IpAddress): bool =
  ## "1.2.3.4" or an IPv6 address (with or without brackets).
  var text = s
  if text.len >= 2 and text[0] == '[' and text[text.len - 1] == ']': text = text.substr(1, text.len - 2)
  var buf = default(array[16, byte])
  if inet_pton(AF_INET, text.toCString, addr buf[0]) == 1:
    ip = ipv4(buf[0], buf[1], buf[2], buf[3])
    return true
  if inet_pton(AF_INET6, text.toCString, addr buf[0]) == 1:
    ip = IpAddress(family: ipv6, bytes: buf)
    return true
  result = false

proc `$`*(ip: IpAddress): string =
  var buf = default(array[64, char])
  let af = if ip.family == ipv4: AF_INET else: AF_INET6
  discard inetNtop(af, unsafeAddr ip.bytes[0], cast[cstring](addr buf[0]), cuint(buf.len))
  result = ""
  var i = 0
  while i < buf.len and buf[i] != '\0':
    result.add buf[i]
    i = i + 1

# -------------------------------------------------------- socket addresses

proc initSocketAddress*(ip: IpAddress; port: uint16): SocketAddress =
  result = default(SocketAddress)
  discard setIpAddr(result.raw, ip.bytes.toOpenArray(0, ipLen(ip) - 1), port,
                    if ip.family == ipv4: AF_INET else: AF_INET6)

proc unixAddress*(path: string): SocketAddress =
  ## A Unix-domain address (at most 103 bytes of path). On Linux, "@name"
  ## is `name` in the abstract namespace: no file, gone with its socket.
  ## Filesystem names reject embedded NUL; Linux abstract names retain it.
  result = default(SocketAddress)
  if path.len == 0 or path.len > 103: return
  let p = cast[ptr UncheckedArray[byte]](addr result.raw.ss)
  when defined(linux):
    if path[0] == '@':
      p[0] = byte(AfUnix)
      p[1] = 0
      p[2] = 0                     # the abstract namespace
      var k = 1
      while k < path.len:
        p[2 + k] = byte(path[k])
        k = k + 1
      result.raw.len = cuint(2 + path.len)
      return
  for ch in path:
    if ch == '\0': return
  let n = 2 + path.len + 1
  when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
    p[0] = byte(n)
    p[1] = byte(AfUnix)
  else:
    p[0] = byte(AfUnix)
    p[1] = 0
  var i = 0
  while i < path.len:
    p[2 + i] = byte(path[i])
    i = i + 1
  result.raw.len = cuint(n)

proc fromRaw*(sa: SockAddrBuf): SocketAddress {.inline.} = SocketAddress(raw: sa)

proc family*(a: SocketAddress): cint {.inline.} = cint(a.raw.ss.ss_family)
proc isValid*(a: SocketAddress): bool {.inline.} = a.raw.len > 0
proc isUnix*(a: SocketAddress): bool {.inline.} = family(a) == AfUnix

proc rawIp*(a: SocketAddress): IpAddress =
  ## Its IP address as the system holds it (IPv4 peers of a dual-stack
  ## socket appear IPv4-mapped).
  let p = cast[ptr UncheckedArray[byte]](unsafeAddr a.raw.ss)
  if family(a) == AF_INET: return ipv4(p[4], p[5], p[6], p[7])
  result = IpAddress(family: ipv6)
  if family(a) == AF_INET6: copyMem(addr result.bytes[0], addr p[8], 16)

proc ip*(a: SocketAddress): IpAddress =
  ## Its IP address; an IPv4-mapped IPv6 address comes back as IPv4.
  result = unmapped(rawIp(a))

proc port*(a: SocketAddress): uint16 =
  if family(a) != AF_INET and family(a) != AF_INET6: return 0
  let p = cast[ptr UncheckedArray[byte]](unsafeAddr a.raw.ss)
  result = (uint16(p[2]) shl 8) or uint16(p[3])

proc path*(a: SocketAddress): string =
  ## A Unix-domain address's path ("" otherwise; "@name" for Linux's
  ## abstract namespace).
  result = ""
  if not isUnix(a): return
  let p = cast[ptr UncheckedArray[byte]](unsafeAddr a.raw.ss)
  if int(a.raw.len) > 2 and p[2] == 0:
    result.add '@'
    var k = 3
    while k < int(a.raw.len):
      result.add char(p[k])
      k = k + 1
    return
  var i = 2
  while i < int(a.raw.len) and p[i] != 0:
    result.add char(p[i])
    i = i + 1

proc `$`*(a: SocketAddress): string =
  ## "1.2.3.4:80", "[2001:db8::1]:443" (IPv4-mapped shown as IPv4), or the
  ## Unix path.
  if isUnix(a): return path(a)
  if not isValid(a): return ""
  let ip = ip(a)
  result = if ip.family == ipv6: "[" & $ip & "]" else: $ip
  result.add ':'
  result.add $port(a)

proc `==`*(a, b: SocketAddress): bool =
  ## Same address and port (Unix: same path); IPv4-mapped equals IPv4.
  if isUnix(a) or isUnix(b): return isUnix(a) and isUnix(b) and path(a) == path(b)
  result = port(a) == port(b) and ip(a) == ip(b)

proc splitHostPort*(s: string; host: var string; port: var uint16): bool =
  ## "host:port", "1.2.3.4:port" or "[v6]:port" into its parts.
  result = false
  var colon = -1
  var i = s.len - 1
  while i >= 0:
    if s[i] == ':':
      colon = i
      break
    i = i - 1
  if colon <= 0 or colon == s.len - 1: return
  var p = 0
  i = colon + 1
  while i < s.len:
    if s[i] < '0' or s[i] > '9': return
    p = p * 10 + ord(s[i]) - ord('0')
    if p > 65535: return
    i = i + 1
  host = s.substr(0, colon - 1)
  if host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']':
    host = host.substr(1, host.len - 2)
  elif host.len > 0 and host[0] == '[':
    return
  port = uint16(p)
  result = host.len > 0

proc parseSocketAddress*(s: string; a: var SocketAddress): bool =
  ## A numeric "ip:port" or "[v6]:port" (no name lookup).
  var host = ""
  var port = 0'u16
  var ip = default(IpAddress)
  if not splitHostPort(s, host, port) or not parseIp(host, ip): return false
  a = initSocketAddress(ip, port)
  result = true

# ---------------------------------------------------------------- resolving


proc parseCidr*(s: string; c: var Cidr): bool =
  ## "10.0.0.0/8", "2001:db8::/32"; a bare address is a single host.
  var slash = -1
  var i = 0
  while i < s.len:
    if s[i] == '/': slash = i
    i = i + 1
  var ip = default(IpAddress)
  if slash < 0:
    if not parseIp(s, ip): return false
    c = Cidr(ip: ip, bits: ipLen(ip) * 8)
    return true
  if not parseIp(s.substr(0, slash - 1), ip): return false
  var bits = 0
  i = slash + 1
  if i >= s.len: return false
  while i < s.len:
    if s[i] < '0' or s[i] > '9': return false
    bits = bits * 10 + ord(s[i]) - ord('0')
    if bits > 128: return false
    i = i + 1
  if bits > ipLen(ip) * 8: return false
  c = Cidr(ip: ip, bits: bits)
  result = true

proc contains*(c: Cidr; ip: IpAddress): bool =
  ## IPv4-mapped IPv6 addresses match IPv4 networks.
  let x = if c.ip.family == ipv4: unmapped(ip) else: ip
  if x.family != c.ip.family: return false
  var left = c.bits
  var i = 0
  while left > 0:
    let mask = if left >= 8: 0xff'u8 else: byte((0xff shl (8 - left)) and 0xff)
    if (x.bytes[i] and mask) != (c.ip.bytes[i] and mask): return false
    left = left - 8
    i = i + 1
  result = true

proc contains*(c: Cidr; a: SocketAddress): bool = contains(c, ip(a))

proc `$`*(c: Cidr): string = $c.ip & "/" & $c.bits

# `echo` writes each argument with `write(stdout, x)`.
proc write*(f: File; ip: IpAddress) = write(f, $ip)
proc write*(f: File; a: SocketAddress) = write(f, $a)
proc write*(f: File; c: Cidr) = write(f, $c)

proc forFamily*(a: SocketAddress; socketFamily: cint): SockAddrBuf =
  ## `a` in the form a socket of `family` takes: an IPv4 address becomes
  ## IPv4-mapped IPv6 for a dual-stack socket. A mapped IPv6 peer becomes
  ## IPv4 when replying from an IPv4-only socket.
  result = a.raw
  if socketFamily == AF_INET6 and family(a) == AF_INET:
    let p = bytesPtr(unsafeAddr a.raw.ss)
    var ip = default(array[16, byte])
    ip[10] = 0xff
    ip[11] = 0xff
    copyMem(addr ip[12], addr p[4], 4)
    discard setIpAddr(result, ip, port(a), AF_INET6)
  elif socketFamily == AF_INET and family(a) == AF_INET6:
    let value = unmapped(ip(a))
    if value.family == ipv4:
      discard setIpAddr(result, value.bytes.toOpenArray(0, 3), port(a), AF_INET)
