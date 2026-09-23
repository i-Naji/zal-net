## Options for proxies, routers and tuned servers, as methods on any socket
## type with a `nativeHandle` and on raw descriptors. Each returns false
## where the system refuses or lacks the option, so callers can degrade
## gracefully. The everyday ones (buffers, keepalive, linger, TTL, TOS)
## are in net/options.
##
## Linux-only: `setMark` (policy routing), `setTransparent` and
## `originalDest` (transparent proxies), `setCongestion`. `bindToDevice`
## is Linux's SO_BINDTODEVICE or macOS's IP_BOUND_IF.

import zal_net/net/sockaddr
import zal_net/net/address
import zal_net/net/options
import zal_net/private/sys/sock

when defined(macosx):
  proc ifNametoindex(name: cstring): cuint {.importc: "if_nametoindex", header: "<net/if.h>".}

const
  SolSocket = (when defined(linux): 1.cint else: 0xffff.cint)
  IpprotoIp = 0.cint
  IpprotoIpv6 = 41.cint
  IpprotoTcp = 6.cint

proc isV6(fd: cint): bool =
  var sa = default(SockAddrBuf)
  sa.len = cuint(sizeof(SockaddrStorage))
  result = sockGetsockname(fd, addr sa.ss, addr sa.len) == 0 and cint(sa.ss.ss_family) == AF_INET6

proc setReusePort*(fd: cint; on = true): bool =
  ## Before bind: several sockets share a port (Linux spreads connections
  ## and datagrams among them). `listenTcp` and `bindUdp` take
  ## `reusePort` for this.
  intOpt(fd, SolSocket, SO_REUSEPORT, ord(on))

proc setUserTimeout*(fd: cint; ms: int): bool =
  ## Drop a TCP connection whose sent data stays unacknowledged for `ms`.
  when defined(linux): result = intOpt(fd, IpprotoTcp, 18.cint, ms)          # TCP_USER_TIMEOUT
  elif defined(macosx): result = intOpt(fd, IpprotoTcp, 0x80.cint, max(1, ms div 1000))  # TCP_RXT_CONNDROPTIME
  elif defined(windows): result = intOpt(fd, IpprotoTcp, 5.cint, max(1, ms div 1000))    # TCP_MAXRT, seconds
  else: result = false

proc setCongestion*(fd: cint; name: string): bool =
  ## TCP congestion control by name ("bbr", "cubic"), Linux only.
  when defined(linux):
    var n = name
    result = sockSetsockopt(fd, IpprotoTcp, 13.cint, n.toCString, cuint(n.len)) == 0   # TCP_CONGESTION
  else:
    result = false

proc setMark*(fd: cint; mark: uint32): bool =
  ## SO_MARK for policy routing (Linux; needs CAP_NET_ADMIN).
  when defined(linux):
    var x = mark
    result = sockSetsockopt(fd, SolSocket, 36.cint, addr x, cuint(sizeof(x))) == 0
  else:
    result = false

proc bindToDevice*(fd: cint; ifname: string): bool =
  ## Send and receive only through interface `ifname`.
  when defined(linux):
    var n = ifname
    result = sockSetsockopt(fd, SolSocket, 25.cint, n.toCString, cuint(n.len)) == 0     # SO_BINDTODEVICE
  elif defined(macosx):
    var n = ifname
    let idx = ifNametoindex(n.toCString)
    if idx == 0: return false
    if isV6(fd): result = intOpt(fd, IpprotoIpv6, 125.cint, int(idx))  # IPV6_BOUND_IF
    else: result = intOpt(fd, IpprotoIp, 25.cint, int(idx))            # IP_BOUND_IF
  else:
    result = false

proc setTransparent*(fd: cint; on = true): bool =
  ## IP_TRANSPARENT: bind to foreign addresses and accept connections to
  ## them (TPROXY; Linux, CAP_NET_ADMIN).
  when defined(linux):
    result = intOpt(fd, IpprotoIp, 19.cint, ord(on))
    if isV6(fd): result = intOpt(fd, IpprotoIpv6, 75.cint, ord(on)) or result
  else:
    result = false

proc originalDest*(fd: cint): SocketAddress =
  ## Where an iptables REDIRECT-ed connection was going (SO_ORIGINAL_DST;
  ## Linux); invalid (`isValid` false) when unknown.
  result = default(SocketAddress)
  when defined(linux):
    var sa = default(SockAddrBuf)
    sa.len = cuint(sizeof(SockaddrStorage))
    if isV6(fd) and sockGetsockopt(fd, IpprotoIpv6, 80.cint, addr sa.ss, addr sa.len) == 0:
      return fromRaw(sa)
    sa.len = cuint(sizeof(SockaddrStorage))
    if sockGetsockopt(fd, IpprotoIp, 80.cint, addr sa.ss, addr sa.len) == 0:
      result = fromRaw(sa)

proc setUserTimeout*[S: NativeSocket](s: S; ms: int): bool = setUserTimeout(nativeHandle(s), ms)
proc setCongestion*[S: NativeSocket](s: S; name: string): bool = setCongestion(nativeHandle(s), name)
proc setMark*[S: NativeSocket](s: S; mark: uint32): bool = setMark(nativeHandle(s), mark)
proc bindToDevice*[S: NativeSocket](s: S; ifname: string): bool = bindToDevice(nativeHandle(s), ifname)
proc setTransparent*[S: NativeSocket](s: S; on = true): bool = setTransparent(nativeHandle(s), on)
proc originalDest*[S: NativeSocket](s: S): SocketAddress = originalDest(nativeHandle(s))
