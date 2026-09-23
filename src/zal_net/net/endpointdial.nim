## Endpoint dialing; imports the runtime and resolver explicitly.
import zal_net/rt
import zal_net/rt/cancel
import zal_net/net/[endpoint, sockaddr, dns, dial]
export endpoint

proc endpointSockAddr*(d: Endpoint; family: cint; sa: var SockAddrBuf): bool =
  ## IP destinations only (family 0: the address's own family).
  if d.kind != epIp4 and d.kind != epIp6: return false
  result = setIpAddr(sa, d.ip.toOpenArray(0, ipLen(d) - 1), d.port, family)

proc endpointAddrs*(d: Endpoint; outp: var array[MaxAddrs, SockAddrBuf]): int =
  ## IP destinations only; 0 for names (see `resolveAsync`).
  result = 0
  if endpointSockAddr(d, 0.cint, outp[0]): result = 1

template dialEndpointInline*(d: Endpoint; noDelay: bool; timeoutMs: int; outFd: var cint;
                             deadline: Deadline = never; tok: nil CancelToken = nil) =
  ## Connect to `d` inline in the caller's passive frame: `outFd` is the
  ## connected socket or -1. Resolution and every connection attempt share
  ## one timeout/deadline budget. Cancellation does not transfer a socket.
  block:
    let endpointToken = tok
    retain(endpointToken)
    let endpointDeadline = earlier(deadline, afterMs(timeoutMs))
    var dAddrs {.noinit.}: array[MaxAddrs, SockAddrBuf]
    var dn = endpointAddrs(d, dAddrs)
    let dNamed = dn == 0 and d.kind == epName
    var dHost = ""
    if dNamed:
      dHost = hostString(d)
      dn = resolveAsync(dHost, d.port, SOCK_STREAM, 0.cint,
                        resolveBuffer(dAddrs), endpointDeadline, endpointToken)
    dialInline(dAddrs, dn, noDelay, timeoutMs, outFd, endpointDeadline, endpointToken)
    if outFd < 0 and dNamed and dn > 0: forgetHost(dHost, SOCK_STREAM, 0.cint)
    release(endpointToken)

proc dialEndpoint*(d: Endpoint; noDelay = true; timeoutMs = 10_000;
                   deadline = never; tok: nil CancelToken = nil): cint {.passive.} =
  var fd: cint = -1
  dialEndpointInline(d, noDelay, timeoutMs, fd, deadline, tok)
  result = fd
