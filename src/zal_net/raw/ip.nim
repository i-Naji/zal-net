## Raw IP: send and receive packets of any IP protocol number. A raw
## socket needs privileges (root, or CAP_NET_RAW on Linux). For ICMP and
## ICMPv6 there is also a datagram variant that ordinary users may open
## (always on macOS; on Linux for the groups in net.ipv4.ping_group_range):
## the kernel then manages the identifier and hands back only echo
## replies meant for the socket. net/icmp builds `ping` on these.
##
## What comes back from `recvFrom` differs by platform and variant: raw
## IPv4 sockets (and macOS's ICMP datagram sockets) deliver the IP header
## in front of the payload; `IpRecvInfo.headerLen` says how long it is,
## and `ttl` is read from it. IPv6 never includes its header.

import zal_net/private/socketowner
import std/oserrors
import zal_net/rt
import zal_net/raw/io
import zal_net/private/sys/posix
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/net/address
import zal_net/raw/fdops
import zal_net/private/sys/sock

type
  IpProtocol* = distinct uint8

  IpSocket* = object
    socket: SocketOwner          ## sole descriptor owner; zero initialization is closed
    family*: cint                 ## AF_INET or AF_INET6
    protocol*: IpProtocol
    datagram*: bool               ## the unprivileged ICMP variant
    timeoutMs*: int
    error*: string

  IpRecvInfo* = object
    source*: IpAddress
    headerLen*: int               ## bytes of IP header in front of the payload (0: none)
    ttl*: int                     ## from that header, else -1

const
  ipIcmp* = IpProtocol(1)
  ipIgmp* = IpProtocol(2)
  ipTcp* = IpProtocol(6)
  ipUdp* = IpProtocol(17)
  ipGre* = IpProtocol(47)
  ipEsp* = IpProtocol(50)
  ipIcmpv6* = IpProtocol(58)
  ipSctp* = IpProtocol(132)
  IpDenied* = -1001               ## privileges missing for this socket

proc `==`*(a, b: IpProtocol): bool {.borrow.}


const
  SockRaw = 3.cint
  EAcces = 13
  EPerm = 1

proc fd(s: IpSocket): cint {.inline.} = handle(s.socket)

proc ok*(s: IpSocket): bool {.inline.} = s.fd >= 0
proc nativeHandle*(s: IpSocket): cint {.inline.} = s.fd

proc openIp*(proto: IpProtocol; v6 = false; datagram = false; timeoutMs = 60_000): IpSocket =
  ## A raw socket for protocol `proto` (IPv4, or IPv6 with `v6`). With
  ## `datagram` (ICMP and ICMPv6 only) the unprivileged variant.
  result = IpSocket(socket: ownedSocket(-1), family: if v6: AF_INET6 else: AF_INET, protocol: proto,
                    datagram: datagram, timeoutMs: timeoutMs)
  let fd = sockSocket(result.family, if datagram: SOCK_DGRAM else: SockRaw, cint(uint8(proto)))
  if fd < 0:
    let err = int(osLastError())
    result.error = if err == EAcces or err == EPerm: "not permitted" else: "socket failed (errno " & $err & ")"
    return
  setNonblock(fd)
  result.socket = ownedSocket(fd)

proc denied*(s: IpSocket): bool = s.fd < 0 and s.error == "not permitted"

proc close*(s: var IpSocket) =
  if s.fd >= 0:
    closeFd(takeHandle(s.socket))

proc sendTo*(s: IpSocket; p: pointer; n: int; dst: IpAddress; deadline = never): int {.passive.} =
  ## One packet (the payload after the IP header, which the kernel adds).
  let a = forFamily(initSocketAddress(dst, 0), s.family)
  let d = limit(s.timeoutMs, deadline)
  var res = 0
  while true:
    let k = sockSendto(s.fd, p, csize_t(n), 0, unsafeAddr a.ss, a.len)
    if k >= 0: return k
    let err = int(osLastError())
    if err == EIntr: continue
    if err != EAgain: return -err
    parkPoll(s.fd, {evWrite}, d, res)
    if res <= 0: return (if res < 0: res else: -1)

proc recvFrom*(s: IpSocket; p: pointer; n: int; info: nil ptr IpRecvInfo = nil; deadline = never): int {.passive.} =
  ## One packet: its length (header included when `info.headerLen` > 0), or
  ## <0 (IoTimedOut, -errno).
  let d = limit(s.timeoutMs, deadline)
  var res = 0
  while true:
    var sa = default(SockAddrBuf)
    sa.len = cuint(sizeof(SockaddrStorage))
    let k = sockRecvfrom(s.fd, p, csize_t(n), 0, addr sa.ss, addr sa.len)
    if k >= 0:
      if info != nil:
        info.source = unmapped(ip(fromRaw(sa)))
        info.headerLen = 0
        info.ttl = -1
        let b = cast[ptr UncheckedArray[byte]](p)
        if s.family == AF_INET and k >= 20 and (b[0] shr 4) == 4 and
           (not s.datagram or defined(macosx)):
          info.headerLen = int(b[0] and 0x0f) * 4
          info.ttl = int(b[8])
      return k
    let err = int(osLastError())
    if err == EIntr: continue
    if err != EAgain: return -err
    parkPoll(s.fd, {evRead}, d, res)
    if res <= 0: return (if res < 0: res else: -1)
