## Endpoint values and parsing. No runtime, resolver, or protocol dependency.
import zal_net/net/sockaddr

type
  EndpointKind* = enum
    epNone, epIp4, epIp6, epName

  Endpoint* = object
    kind*: EndpointKind
    port*: uint16
    hostLen*: int                  # domain names only
    ip*: array[16, byte]           # the first 4 bytes for IPv4
    host*: array[255, char]        # domain names only; not NUL-terminated

proc valid*(d: Endpoint): bool {.inline.} = d.kind != epNone

proc ipLen*(d: Endpoint): int {.inline.} =
  if d.kind == epIp4: 4
  elif d.kind == epIp6: 16
  else: 0

proc setIp*(d: var Endpoint; ip: openArray[byte]; port: uint16): bool =
  ## 4 or 16 raw bytes.
  if ip.len != 4 and ip.len != 16: return false
  d.kind = if ip.len == 4: epIp4 else: epIp6
  copyMem(addr d.ip[0], unsafeAddr ip[0], ip.len)
  d.hostLen = 0
  d.port = port
  result = true

proc setName*(d: var Endpoint; name: openArray[char]; port: uint16): bool =
  ## 1..255 bytes, no NUL (it would cut the name short in the resolver).
  if name.len == 0 or name.len > 255: return false
  var i = 0
  while i < name.len:
    if name[i] == '\0': return false
    d.host[i] = name[i]
    i = i + 1
  d.kind = epName
  d.hostLen = name.len
  d.port = port
  result = true

proc hexDigit(n: int): char =
  let v = n and 0xf
  result = if v < 10: char(ord('0') + v) else: char(ord('a') + v - 10)

proc hostString*(d: Endpoint): string =
  ## The host as text: a name, dotted IPv4, or full-form IPv6.
  result = ""
  case d.kind
  of epName:
    var i = 0
    while i < d.hostLen:
      result.add d.host[i]
      i = i + 1
  of epIp4:
    result = $d.ip[0] & "." & $d.ip[1] & "." & $d.ip[2] & "." & $d.ip[3]
  of epIp6:
    var g = 0
    while g < 8:
      if g > 0: result.add ':'
      let hi = int(d.ip[g * 2])
      let lo = int(d.ip[g * 2 + 1])
      result.add hexDigit(hi shr 4)
      result.add hexDigit(hi)
      result.add hexDigit(lo shr 4)
      result.add hexDigit(lo)
      g = g + 1
  of epNone: discard

proc formatEndpoint*(d: Endpoint): string =
  ## "host:port", with IPv6 in brackets; for logs and the API.
  if d.kind == epIp6: result = "[" & hostString(d) & "]:" & $d.port
  else: result = hostString(d) & ":" & $d.port

proc parsePort(s: openArray[char]; port: var uint16): bool =
  if s.len == 0 or s.len > 5: return false
  var n = 0
  for c in s:
    if c < '0' or c > '9': return false
    n = n * 10 + ord(c) - ord('0')
  if n > 65535: return false
  port = uint16(n)
  result = true

proc parseHost*(s: openArray[char]; port: uint16; d: var Endpoint): bool =
  ## An IP literal (IPv6 without brackets) or a domain name.
  if s.len == 0 or s.len > 255: return false
  var text = newString(s.len)
  var i = 0
  while i < s.len:
    text[i] = s[i]
    i = i + 1
  var ip = default(array[16, byte])
  if inet_pton(AF_INET, text.toCString, addr ip[0]) == 1:
    return setIp(d, ip.toOpenArray(0, 3), port)
  if inet_pton(AF_INET6, text.toCString, addr ip[0]) == 1:
    return setIp(d, ip, port)
  result = setName(d, s, port)

proc parseHostPort*(s: openArray[char]; d: var Endpoint): bool =
  ## "host:port", "1.2.3.4:port" or "[v6]:port".
  result = false
  d.kind = epNone
  if s.len < 3: return
  var colon = s.len - 1
  while colon >= 0 and s[colon] != ':': colon = colon - 1
  if colon <= 0: return
  var port = 0'u16
  if not parsePort(s.toOpenArray(colon + 1, s.len - 1), port): return
  if s[0] == '[':
    if s[colon - 1] != ']' or colon < 3: return
    var ip = default(array[16, byte])
    var text = newString(colon - 2)
    var i = 0
    while i < colon - 2:
      text[i] = s[i + 1]
      i = i + 1
    if inet_pton(AF_INET6, text.toCString, addr ip[0]) != 1: return
    return setIp(d, ip, port)
  var k = 0
  while k < colon:
    if s[k] == ':': return   # a bare IPv6 address needs brackets
    k = k + 1
  result = parseHost(s.toOpenArray(0, colon - 1), port, d)


type EndpointView* = object
  ## Protocol-neutral borrowed IP/name bytes. Valid only while their owner is
  ## alive and unchanged. IP lengths are 4/16; a name contains 1..255 non-NUL bytes.
  kind*: EndpointKind
  port*: uint16
  data*: nil ptr UncheckedArray[byte]
  len*: int

proc valid*(v: EndpointView): bool =
  let p = v.data
  if p == nil: return false
  case v.kind
  of epIp4: result = v.len == 4
  of epIp6: result = v.len == 16
  of epName:
    if v.len < 1 or v.len > 255: return false
    for i in 0 ..< v.len:
      if p[i] == 0: return false
    result = true
  of epNone: result = false

proc endpointView*(d: var Endpoint): EndpointView {.inline.} =
  ## Borrow an address-stable endpoint; never call on a temporary value.
  result = EndpointView(kind: d.kind, port: d.port)
  if d.kind == epName:
    result.data = cast[ptr UncheckedArray[byte]](addr d.host[0])
    result.len = d.hostLen
  elif d.kind == epIp4 or d.kind == epIp6:
    result.data = cast[ptr UncheckedArray[byte]](addr d.ip[0])
    result.len = ipLen(d)

proc toEndpoint*(v: EndpointView; d: var Endpoint): bool =
  ## Copy a borrowed view into an owned value. Invalid views leave d empty.
  d.kind = epNone
  if not valid(v): return false
  let p = v.data
  if p == nil: return false
  d.kind = v.kind
  d.port = v.port
  d.hostLen = 0
  if v.kind == epName:
    d.hostLen = v.len
    copyMem(addr d.host[0], p, v.len)
  else:
    copyMem(addr d.ip[0], p, v.len)
  result = true

proc socketEndpointView*(name: ptr SockaddrStorage; nameLen: cuint): EndpointView =
  ## Borrow native address storage; normalize IPv4-mapped IPv6 without a copy.
  result = default(EndpointView)
  let raw = cast[ptr UncheckedArray[byte]](name)
  let family = cint(name.ss_family)
  if family == AF_INET and nameLen >= 16:
    result = EndpointView(kind: epIp4, len: 4, data: cast[ptr UncheckedArray[byte]](addr raw[4]))
  elif family == AF_INET6 and nameLen >= 24:
    var mapped = raw[18] == 0xff and raw[19] == 0xff
    for i in 8 ..< 18:
      if raw[i] != 0: mapped = false
    if mapped:
      result = EndpointView(kind: epIp4, len: 4, data: cast[ptr UncheckedArray[byte]](addr raw[20]))
    else:
      result = EndpointView(kind: epIp6, len: 16, data: cast[ptr UncheckedArray[byte]](addr raw[8]))
  else:
    return
  result.port = (uint16(raw[2]) shl 8) or uint16(raw[3])
