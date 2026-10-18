## UDP sockets, unconnected (`sendTo`/`recvFrom`) and connected (`send`/
## `recv`), IPv4 and IPv6 on one socket, plus batches of datagrams per
## system call (recvmmsg/sendmmsg; GRO segments on Linux: see net/mmsg and
## net/gso). Every wait ends at the earlier of the socket's `timeoutMs` and
## the operation's `deadline`; results: bytes, or <0 (IoTimedOut, -errno).
##
## ```nim
## var u = bindUdp(5353)
## var buf = default(array[1500, byte])
## var src = default(SocketAddress)
## let n = recvFrom(u, buf, src)
## if n >= 0: discard sendTo(u, buf.toOpenArray(0, n - 1), src)
## ```

import zal_net/net/dns as resolver
import zal_net/errors
import zal_net/rt/cancel
import zal_net/private/core/iocancel
import zal_net/private/core/udpops
import zal_net/private/socketowner
import std/oserrors
import zal_net/rt
import zal_net/raw/io
import zal_net/private/sys/posix
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/raw/mmsg
import zal_net/net/address
import zal_net/raw/fdops
import zal_net/private/sys/sock
import zal_net/private/sys/dgram
import zal_net/net/datagraminfo
export datagraminfo

export DefaultTimeoutMs, BatchResult



type
  UdpSocket* = object
    socket: SocketOwner          ## sole descriptor owner; zero initialization is closed
    family*: cint                ## AF_INET6 (dual stack) or AF_INET
    timeoutMs*: int
    error*: string

  UdpSocketPtr* = ptr UdpSocket


proc fd(u: UdpSocket): cint {.inline.} = handle(u.socket)

proc ok*(u: UdpSocket): bool {.inline.} = u.fd >= 0
proc nativeHandle*(u: UdpSocket): cint {.inline.} = u.fd
proc localAddress*(u: UdpSocket): SocketAddress = fdLocal(u.fd)
proc remoteAddress*(u: UdpSocket): SocketAddress = fdRemote(u.fd)

proc adoptUdp*(owner: UdpSocketPtr; descriptor: var cint; family: cint;
               timeoutMs = DefaultTimeoutMs): bool =
  ## Adopt a nonblocking datagram socket of this family, with no pending work.
  ## Caller verifies those native properties. Failure preserves both owners.
  if owner[].ok or descriptor < 0 or (family != AF_INET and family != AF_INET6): return false
  owner.socket = ownedSocket(descriptor)
  owner.family = family
  owner.timeoutMs = timeoutMs
  owner.error = ""
  descriptor = -1
  result = true

proc takeNativeHandle*(owner: UdpSocketPtr): cint =
  ## Detach only when quiescent. The caller assumes socket ownership.
  takeHandle(owner.socket)

proc takeUdp*(owner: UdpSocketPtr): UdpSocket =
  ## Transfer only when no operation still borrows the raw owner.
  result = owner[]
  owner.socket = default(SocketOwner)

proc bindUdpInto*(owner: UdpSocketPtr; port: uint16 = 0; host = "";
                  timeoutMs = DefaultTimeoutMs; reusePort = false): int =
  ## Exact bind result. Failure preserves every output-owner field.
  if owner[].ok: return ResourceBusy
  if stopping(): return ResourceClosed
  let opened = tryListenUdp(port, host, reusePort)
  if not opened.ok: return opened.code
  var local = default(SocketAddress)
  local.raw.len = cuint(sizeof(SockaddrStorage))
  if sockGetsockname(opened.fd, addr local.raw.ss, addr local.raw.len) != 0:
    let code = -int(osLastError())
    closeFd(opened.fd)
    return code
  owner.socket = ownedSocket(opened.fd)
  owner.family = address.family(local)
  owner.timeoutMs = timeoutMs
  owner.error = ""
  result = 0

proc openUdpInto*(owner: UdpSocketPtr; timeoutMs = DefaultTimeoutMs): int =
  ## Unbound dual stack with IPv4 fallback. Failure preserves the output owner.
  if owner[].ok: return ResourceBusy
  if stopping(): return ResourceClosed
  var family: cint = 0
  var code = 0
  let fd = openUdpSocket(family, addr code)
  if fd < 0: return code
  owner.socket = ownedSocket(fd)
  owner.family = family
  owner.timeoutMs = timeoutMs
  owner.error = ""
  result = 0

proc connectUdpInto*(owner: UdpSocketPtr; remote: SocketAddress;
                     timeoutMs = DefaultTimeoutMs; deadline: Deadline = never;
                     tok: nil CancelToken = nil): int =
  ## Synchronous UDP association, not a reachability/handshake test. Failure
  ## closes the temporary socket and preserves the output owner.
  if owner[].ok: return ResourceBusy
  if stopping(): return ResourceClosed
  if cancelled(tok): return ECancelled
  if monoNow() >= deadline: return IoTimedOut
  let family = address.family(remote)
  if family != AF_INET and family != AF_INET6: return InvalidInput
  var temporary = default(UdpSocket)
  result = openUdpInto(addr temporary, timeoutMs)
  if result != 0: return
  let sa = forFamily(remote, temporary.family)
  if sockConnect(temporary.fd, unsafeAddr sa.ss, sa.len) != 0:
    result = -int(osLastError())
    closeFd(takeHandle(temporary.socket))
    return
  if cancelled(tok) or stopping() or monoNow() >= deadline:
    result = if cancelled(tok): ECancelled elif stopping(): ResourceClosed else: IoTimedOut
    closeFd(takeHandle(temporary.socket))
    return
  owner[] = takeUdp(addr temporary)

proc connectUdpInto*(owner: UdpSocketPtr; host: string; port: uint16;
                     timeoutMs = DefaultTimeoutMs; deadline: Deadline = never;
                     tok: nil CancelToken = nil): int {.passive.} =
  ## Resolve off-loop, then try addresses under one deadline/token. Failure
  ## preserves the output; a successful UDP association does not probe its peer.
  if owner[].ok: return ResourceBusy
  if stopping(): return ResourceClosed
  retain(tok)
  defer: release(tok)
  var addresses = default(array[MaxAddrs, SockAddrBuf])
  let count = resolver.resolveAsync(host, port, SOCK_DGRAM, 0.cint,
                                    resolver.resolveBuffer(addresses), deadline, tok)
  if count < 0: return count
  if count == 0: return DnsNoAddresses
  var firstError = 0
  for i in 0..<count:
    let code = connectUdpInto(owner, fromRaw(addresses[i]), timeoutMs, deadline, tok)
    if code == 0: return 0
    if code == ECancelled or code == IoTimedOut or code == ResourceClosed: return code
    if firstError == 0: firstError = code
  result = firstError

proc bindUdp*(port: uint16 = 0; host = ""; timeoutMs = DefaultTimeoutMs; reusePort = false): UdpSocket =
  ## Bound to host, or every address when empty. Port zero asks the kernel.
  result = default(UdpSocket)
  let code = bindUdpInto(addr result, port, host, timeoutMs, reusePort)
  if code != 0: result.error = errors.describe(code)

proc bindUdp*(a: SocketAddress; timeoutMs = DefaultTimeoutMs; reusePort = false): UdpSocket =
  let ip = unmapped(ip(a))
  result = bindUdp(port(a), if isUnspecified(ip): "" else: $ip, timeoutMs, reusePort)

proc openUdp*(timeoutMs = DefaultTimeoutMs): UdpSocket =
  result = default(UdpSocket)
  let code = openUdpInto(addr result, timeoutMs)
  if code != 0: result.error = errors.describe(code)

proc connectUdp*(remote: SocketAddress; timeoutMs = DefaultTimeoutMs): UdpSocket =
  result = default(UdpSocket)
  let code = connectUdpInto(addr result, remote, timeoutMs)
  if code != 0: result.error = errors.describe(code)

template connectUdp*(host: string; port: uint16; timeoutMs = DefaultTimeoutMs;
                     deadline: Deadline = never; tok: nil CancelToken = nil): UdpSocket =
  block:
    var owner = default(UdpSocket)
    let name = host
    let code = connectUdpInto(addr owner, name, port, timeoutMs, deadline, tok)
    if code != 0: owner.error = errors.describe(code)
    owner

proc close*(u: var UdpSocket) =
  if u.fd >= 0:
    closeFd(takeHandle(u.socket))

template sendTo*(u: UdpSocket; p: pointer; n: int; to: SocketAddress;
                 deadline: Deadline = never; tok: nil CancelToken = nil): int =
  udpSendTo(nativeHandle(u), u.family, u.timeoutMs, p, n, to, deadline, ioCancellation(tok))

template recvFrom*(u: UdpSocket; p: pointer; n: int; src: nil ptr SocketAddress = nil;
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  udpRecvFrom(nativeHandle(u), u.timeoutMs, p, n, src, deadline, ioCancellation(tok))

template send*(u: UdpSocket; p: pointer; n: int; deadline: Deadline = never;
               tok: nil CancelToken = nil): int =
  udpSend(nativeHandle(u), u.timeoutMs, p, n, deadline, ioCancellation(tok))

template recv*(u: UdpSocket; p: pointer; n: int; deadline: Deadline = never;
               tok: nil CancelToken = nil): int =
  udpRecv(nativeHandle(u), u.timeoutMs, p, n, deadline, ioCancellation(tok))

template recvBatch*(u: UdpSocket; b: ptr MmsgBatch; deadline: Deadline = never;
                    tok: nil CancelToken = nil): int =
  udpRecvBatch(nativeHandle(u), u.timeoutMs, b, deadline, ioCancellation(tok))

template sendBatch*(u: UdpSocket; b: ptr MmsgBatch; n: int; deadline: Deadline = never;
                    tok: nil CancelToken = nil; first = 0): BatchResult =
  udpSendBatch(nativeHandle(u), u.timeoutMs, b, n, deadline, ioCancellation(tok), first)

template sendTo*(u: UdpSocket; buf: openArray[byte]; to: SocketAddress; deadline: Deadline = never;
                 tok: nil CancelToken = nil): int =
  sendTo(u, dataPtr(buf), buf.len, to, deadline, tok)

template recvFrom*(u: UdpSocket; buf: var openArray[byte]; src: var SocketAddress; deadline: Deadline = never;
                   tok: nil CancelToken = nil): int =
  recvFrom(u, dataPtr(buf), buf.len, addr src, deadline, tok)

template send*(u: UdpSocket; buf: openArray[byte]; deadline: Deadline = never;
               tok: nil CancelToken = nil): int =
  send(u, dataPtr(buf), buf.len, deadline, tok)
template recv*(u: UdpSocket; buf: var openArray[byte]; deadline: Deadline = never;
               tok: nil CancelToken = nil): int =
  recv(u, dataPtr(buf), buf.len, deadline, tok)

# ------------------------------------------------------------- metadata

proc enableInfo*(u: UdpSocket): bool =
  ## Have the kernel attach destination, interface, TTL/hop limit and
  ## TOS/traffic class to received datagrams (read them with the
  ## DatagramInfo form of `recvFrom`).
  result = u.fd >= 0 and nnEnableInfo(u.fd) > 0

template recvFrom*(u: UdpSocket; p: pointer; n: int; info: ptr DatagramInfo;
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  udpRecvInfo(nativeHandle(u), u.timeoutMs, p, n, info, deadline, ioCancellation(tok))

template sendWithSource*(u: UdpSocket; p: pointer; n: int; to: SocketAddress;
                         source: IpAddress; ifIndex = 0'u32; deadline: Deadline = never;
                         tok: nil CancelToken = nil): int =
  udpSendWithSource(nativeHandle(u), u.family, u.timeoutMs, p, n, to, source,
                    ifIndex, deadline, ioCancellation(tok))

# ------------------------------------------------- multicast and broadcast

proc joinGroup*(u: UdpSocket; group: IpAddress; ifIndex = 0'u32): bool =
  ## Receive datagrams sent to multicast `group` on interface `ifIndex`
  ## (0: the kernel's choice). IPv4 groups: bind the socket to 0.0.0.0 (or
  ## the group) and its port first.
  let g = initSocketAddress(group, 0)
  result = nnMembership(u.fd, 1, unsafeAddr g.raw.ss, g.raw.len, cuint(ifIndex)) == 0

proc leaveGroup*(u: UdpSocket; group: IpAddress; ifIndex = 0'u32): bool =
  let g = initSocketAddress(group, 0)
  result = nnMembership(u.fd, 0, unsafeAddr g.raw.ss, g.raw.len, cuint(ifIndex)) == 0

proc setMulticastInterface*(u: UdpSocket; ifIndex: uint32; v6 = false): bool =
  ## The interface multicast leaves through.
  result = nnMcastIf(u.fd, cint(ord(v6)), cuint(ifIndex)) == 0

proc setMulticastTtl*(u: UdpSocket; ttl: int; v6 = false): bool =
  result = ttl >= 0 and ttl <= 255 and nnMcastTtl(u.fd, cint(ord(v6)), cint(ttl)) == 0

proc setMulticastLoop*(u: UdpSocket; on: bool; v6 = false): bool =
  ## Whether this host's own members receive what it sends.
  result = nnMcastLoop(u.fd, cint(ord(v6)), cint(ord(on))) == 0

proc setBroadcast*(u: UdpSocket; on = true): bool =
  ## Allow sends to broadcast addresses.
  var v = cint(ord(on))
  let solSocket = when defined(linux): 1.cint else: 0xffff.cint
  let soBroadcast = when defined(linux): 6.cint else: 0x20.cint
  result = sockSetsockopt(u.fd, solSocket, soBroadcast, addr v, cuint(sizeof(v))) == 0

template recvFrom*(u: UdpSocket; buf: var openArray[byte]; info: var DatagramInfo; deadline: Deadline = never;
                   tok: nil CancelToken = nil): int =
  recvFrom(u, dataPtr(buf), buf.len, addr info, deadline, tok)

template sendWithSource*(u: UdpSocket; buf: openArray[byte]; to: SocketAddress; source: IpAddress;
                   ifIndex: uint32 = 0'u32; deadline: Deadline = never;
                   tok: nil CancelToken = nil): int =
  sendWithSource(u, dataPtr(buf), buf.len, to, source, ifIndex, deadline, tok)
