## Optional SOCKS address serialization. Views borrow the input buffer.
import zal_net/bytes
import zal_net/net/[endpoint, sockaddr]

type
  SocksAddrView* = object
    ## A SOCKS address inside a buffer, not copied: the IP bytes or the name
    ## are at `off` and are `len` long.
    kind*: EndpointKind
    off*, len*: int
    port*: uint16
    used*: int                     # bytes the whole address takes

const
  AtypIp4* = 1'u8
  AtypDomain* = 3'u8
  AtypIp6* = 4'u8
  MaxSocksAddr* = 1 + 1 + 255 + 2

proc viewSocksAddr*(p: ptr UncheckedArray[byte]; start, limit: int; v: var SocksAddrView): bool =
  ## Parse the SOCKS address at p[start ..< limit] without copying it.
  result = false
  v.kind = epNone
  if start < 0 or start >= limit: return
  let atyp = p[start]
  var i = start + 1
  if atyp == AtypIp4 or atyp == AtypIp6:
    let n = if atyp == AtypIp4: 4 else: 16
    if i + n + 2 > limit: return
    v.kind = if atyp == AtypIp4: epIp4 else: epIp6
    v.off = i
    v.len = n
    i = i + n
  elif atyp == AtypDomain:
    if i >= limit: return
    let n = int(p[i])
    i = i + 1
    if n == 0 or i + n + 2 > limit: return
    var k = 0
    while k < n:
      if p[i + k] == 0: return
      k = k + 1
    v.kind = epName
    v.off = i
    v.len = n
    i = i + n
  else:
    return
  v.port = beU16(p, i)
  v.used = i + 2 - start
  result = true

proc toEndpoint*(p: ptr UncheckedArray[byte]; v: SocksAddrView; d: var Endpoint): bool =
  if v.kind == epName:
    result = setName(d, cast[ptr UncheckedArray[char]](addr p[v.off]).toOpenArray(0, v.len - 1), v.port)
  elif v.kind == epIp4 or v.kind == epIp6:
    result = setIp(d, p.toOpenArray(v.off, v.off + v.len - 1), v.port)
  else:
    result = false

proc parseSocksAddr*(buf: openArray[byte]; d: var Endpoint): int =
  ## The SOCKS address at the start of `buf`: bytes used, or -1.
  result = -1
  d.kind = epNone
  if buf.len == 0: return
  let p = cast[ptr UncheckedArray[byte]](unsafeAddr buf[0])
  var v = default(SocksAddrView)
  if viewSocksAddr(p, 0, buf.len, v) and toEndpoint(p, v, d): result = v.used

proc socksAddrLen*(d: Endpoint): int =
  case d.kind
  of epIp4: 1 + 4 + 2
  of epIp6: 1 + 16 + 2
  of epName: 1 + 1 + d.hostLen + 2
  of epNone: 0

proc encodeSocksAddr*(d: Endpoint; buf: var openArray[byte]; start: int): int =
  ## Write `d` at buf[start]; bytes written, or 0 when it does not fit.
  let n = socksAddrLen(d)
  if n == 0 or start < 0 or start + n > buf.len: return 0
  var i = start
  case d.kind
  of epIp4, epIp6:
    buf[i] = if d.kind == epIp4: AtypIp4 else: AtypIp6
    copyMem(addr buf[i + 1], unsafeAddr d.ip[0], ipLen(d))
    i = i + 1 + ipLen(d)
  of epName:
    buf[i] = AtypDomain
    buf[i + 1] = byte(d.hostLen)
    copyMem(addr buf[i + 2], unsafeAddr d.host[0], d.hostLen)
    i = i + 2 + d.hostLen
  of epNone: return 0
  putU16be(buf, i, d.port)
  result = n

proc sockToSocksAddr*(name: SockaddrStorage; nameLen: cuint; p: ptr UncheckedArray[byte]; at: int): int =
  ## A socket address as a SOCKS address at p[at]: bytes written, or 0.
  ## IPv4-mapped IPv6 (from a dual-stack socket) becomes plain IPv4, the
  ## address the peer actually used.
  let raw = cast[ptr UncheckedArray[byte]](unsafeAddr name)
  let fam = cint(name.ss_family)
  if fam == AF_INET and nameLen >= 16:
    p[at] = AtypIp4
    copyMem(addr p[at + 1], addr raw[4], 4)
    p[at + 5] = raw[2]
    p[at + 6] = raw[3]
    return 7
  if fam == AF_INET6 and nameLen >= 24:
    var mapped = raw[18] == 0xff and raw[19] == 0xff
    var k = 8
    while mapped and k < 18:
      if raw[k] != 0: mapped = false
      k = k + 1
    if mapped:
      p[at] = AtypIp4
      copyMem(addr p[at + 1], addr raw[20], 4)
      p[at + 5] = raw[2]
      p[at + 6] = raw[3]
      return 7
    p[at] = AtypIp6
    copyMem(addr p[at + 1], addr raw[8], 16)
    p[at + 17] = raw[2]
    p[at + 18] = raw[3]
    return 19
  result = 0


proc endpointView*(p: ptr UncheckedArray[byte]; v: SocksAddrView): EndpointView {.inline.} =
  ## Borrow a successfully parsed SOCKS view as a protocol-neutral endpoint.
  result = EndpointView(kind: v.kind, port: v.port, len: v.len,
                        data: cast[ptr UncheckedArray[byte]](addr p[v.off]))

proc encodeSocksAddr*(v: EndpointView; p: ptr UncheckedArray[byte]; cap: int): int =
  ## Serialize a borrowed endpoint without first copying it to an owned value.
  if not valid(v): return 0
  let data = v.data
  if data == nil: return 0
  let prefix = if v.kind == epName: 2 else: 1
  let n = prefix + v.len + 2
  if cap < n: return 0
  p[0] = if v.kind == epName: AtypDomain elif v.kind == epIp4: AtypIp4 else: AtypIp6
  if prefix == 2: p[1] = byte(v.len)
  copyMem(addr p[prefix], data, v.len)
  p[prefix + v.len] = byte(v.port shr 8)
  p[prefix + v.len + 1] = byte(v.port and 0xff)
  result = n
