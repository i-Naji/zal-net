## Common socket options, as methods on any socket type (TcpStream,
## TcpListener, UdpSocket, UnixStream, IpSocket...: whatever has a
## `nativeHandle`) and on raw descriptors. Each returns false where the
## system refuses or lacks the option.
##
## ```nim
## discard setKeepAlive(s, idleSec = 30)
## discard setRecvBuffer(u, 4 shl 20)
## discard setTtl(u, 1)
## ```
##
## Options for proxies and routers (marks, transparent sockets, binding to
## a device, congestion control, the original destination) are in
## net/advanced.

import zal_net/net/sockaddr
import zal_net/private/sys/sock
import zal_net/private/sys/types

type
  NativeSocket* = concept
    proc nativeHandle(s: Self): cint



const
  IpprotoIp = 0.cint
  IpprotoIpv6 = 41.cint
  IpprotoTcp = 6.cint
  TcpNodelay = 1.cint

when defined(linux):
  const
    SolSocket = 1.cint
    SoKeepalive = 9.cint
    SoLinger = 13.cint
    SoRcvbuf = 8.cint
    SoSndbuf = 7.cint
    TcpKeepidle = 4.cint
    TcpKeepintvl = 5.cint
    TcpKeepcnt = 6.cint
    IpTtl = 2.cint
    IpTos = 1.cint
    Ipv6UnicastHops = 16.cint
    Ipv6Tclass = 67.cint
elif defined(windows):
  const
    SolSocket = 0xffff.cint
    SoKeepalive = 0x8.cint
    SoLinger = 0x80.cint
    SoRcvbuf = 0x1002.cint
    SoSndbuf = 0x1001.cint
    TcpKeepidle = 3.cint           # TCP_KEEPALIVE (TCP_KEEPIDLE), Windows 10 1709+
    TcpKeepintvl = 17.cint
    TcpKeepcnt = 16.cint
    IpTtl = 4.cint
    IpTos = 3.cint
    Ipv6UnicastHops = 4.cint
    Ipv6Tclass = 39.cint
else:
  const
    SolSocket = 0xffff.cint
    SoKeepalive = 0x8.cint
    SoLinger = 0x1080.cint         # SO_LINGER_SEC
    SoRcvbuf = 0x1002.cint
    SoSndbuf = 0x1001.cint
    TcpKeepidle = 0x10.cint        # TCP_KEEPALIVE
    TcpKeepintvl = 0x101.cint
    TcpKeepcnt = 0x102.cint
    IpTtl = 4.cint
    IpTos = 3.cint
    Ipv6UnicastHops = 4.cint
    Ipv6Tclass = 36.cint

proc intOpt*(fd, level, opt: cint; v: int): bool =
  ## Any integer option: sockSetsockopt(fd, level, opt, v).
  var x = cint(v)
  result = sockSetsockopt(fd, level, opt, addr x, cuint(sizeof(x))) == 0

proc getIntOpt*(fd, level, opt: cint): int =
  ## Any integer option, or -1.
  var x: cint = 0
  var n = cuint(sizeof(x))
  result = if sockGetsockopt(fd, level, opt, addr x, addr n) == 0: int(x) else: -1

proc isV6(fd: cint): bool =
  var sa = default(SockAddrBuf)
  sa.len = cuint(sizeof(SockaddrStorage))
  result = sockGetsockname(fd, addr sa.ss, addr sa.len) == 0 and cint(sa.ss.ss_family) == AF_INET6

# ------------------------------------------------------------- descriptors

proc setRecvBuffer*(fd: cint; bytes: int): bool = intOpt(fd, SolSocket, SoRcvbuf, bytes)
proc setSendBuffer*(fd: cint; bytes: int): bool = intOpt(fd, SolSocket, SoSndbuf, bytes)
proc recvBuffer*(fd: cint): int = getIntOpt(fd, SolSocket, SoRcvbuf)
  ## What the kernel granted (Linux reports twice the request).
proc sendBuffer*(fd: cint): int = getIntOpt(fd, SolSocket, SoSndbuf)

proc setNoDelay*(fd: cint; on: bool): bool = intOpt(fd, IpprotoTcp, TcpNodelay, ord(on))

when defined(windows):
  proc nnKeepaliveVals(fd, on, idleMs, intervalMs: cint): cint {.importc: "nn_keepalive_vals".}

proc setKeepAlive*(fd: cint; on = true; idleSec = 60; intervalSec = 10; count = 6): bool =
  ## TCP keepalive: after `idleSec` of silence, a probe every
  ## `intervalSec`; the connection fails after `count` unanswered ones
  ## (Windows before 10 1709: the system's count, 10).
  result = intOpt(fd, SolSocket, SoKeepalive, ord(on))
  if result and on:
    result = intOpt(fd, IpprotoTcp, TcpKeepidle, idleSec) and
             intOpt(fd, IpprotoTcp, TcpKeepintvl, intervalSec) and
             intOpt(fd, IpprotoTcp, TcpKeepcnt, count)
    when defined(windows):
      if not result:
        result = nnKeepaliveVals(fd, 1, cint(idleSec * 1000), cint(intervalSec * 1000)) == 0

proc setLinger*(fd: cint; seconds: int): bool =
  ## How close treats unsent data: -1 the default (in the background), 0
  ## discard it and reset the connection, >0 block close up to that long.
  when defined(windows):
    var l = Linger(l_onoff: uint16(ord(seconds >= 0)), l_linger: uint16(min(max(seconds, 0), 65535)))
  else:
    var l = Linger(l_onoff: cint(ord(seconds >= 0)), l_linger: cint(max(seconds, 0)))
  result = sockSetsockopt(fd, SolSocket, SoLinger, addr l, cuint(sizeof(l))) == 0

proc setTtl*(fd: cint; ttl: int): bool =
  ## Unicast TTL (IPv4) or hop limit (IPv6; on a dual-stack socket both).
  if isV6(fd):
    result = intOpt(fd, IpprotoIpv6, Ipv6UnicastHops, ttl)
    discard intOpt(fd, IpprotoIp, IpTtl, ttl)
  else:
    result = intOpt(fd, IpprotoIp, IpTtl, ttl)

proc ttl*(fd: cint): int =
  result = if isV6(fd): getIntOpt(fd, IpprotoIpv6, Ipv6UnicastHops) else: getIntOpt(fd, IpprotoIp, IpTtl)

proc setTos*(fd: cint; tos: int): bool =
  ## The IPv4 TOS byte or IPv6 traffic class: DSCP << 2 | ECN.
  if isV6(fd):
    result = intOpt(fd, IpprotoIpv6, Ipv6Tclass, tos)
    discard intOpt(fd, IpprotoIp, IpTos, tos)
  else:
    result = intOpt(fd, IpprotoIp, IpTos, tos)

# ----------------------------------------------------------------- methods

proc setRecvBuffer*[S: NativeSocket](s: S; bytes: int): bool = setRecvBuffer(nativeHandle(s), bytes)
proc setSendBuffer*[S: NativeSocket](s: S; bytes: int): bool = setSendBuffer(nativeHandle(s), bytes)
proc recvBuffer*[S: NativeSocket](s: S): int = recvBuffer(nativeHandle(s))
proc sendBuffer*[S: NativeSocket](s: S): int = sendBuffer(nativeHandle(s))
proc setKeepAlive*[S: NativeSocket](s: S; on = true; idleSec = 60; intervalSec = 10; count = 6): bool =
  setKeepAlive(nativeHandle(s), on, idleSec, intervalSec, count)
proc setLinger*[S: NativeSocket](s: S; seconds: int): bool = setLinger(nativeHandle(s), seconds)
proc setTtl*[S: NativeSocket](s: S; ttl: int): bool = setTtl(nativeHandle(s), ttl)
proc ttl*[S: NativeSocket](s: S): int = ttl(nativeHandle(s))
proc setTos*[S: NativeSocket](s: S; tos: int): bool = setTos(nativeHandle(s), tos)
