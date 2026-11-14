# Outbound connections as a value a server holds.
#
#   var direct = DirectDialer(noDelay: true, timeoutMs: 10_000, device: "eth1")
#   server.dialer = dialer(addr direct)
#
#   let got = dialStream(server.dialer, destination, deadline, stopToken)
#   if got.fd < 0: refuse(got.code)
#
# A proxy accepts a connection, learns where it should go, and connects
# there. Where "there" is reached from is a policy: straight out, through one
# interface, with a routing mark, through another proxy. A `Dialer` is that
# policy as a context and a proc, so a server asks its dialer and does not
# know which one it has.
#
# `DirectDialer` is the one that connects straight out. A protocol library
# that reaches its destination through a server of its own (a SOCKS client,
# a Shadowsocks client) offers its own `Dialer`, usually on top of another
# one that reaches that server, and that is how outbounds chain.
#
# A dial costs one passive frame more than `dialEndpointInline`. That is
# paid once per connection and never per read or write.

import zal_net/rt
import zal_net/rt/[cancel, time]
import zal_net/raw/[io, socket, advanced]
import zal_net/net/[endpoint, endpointdial, sockaddr, dns]
import zal_net/private/core/iocancel
import zal_net/errors

type
  Dialed* = object
    ## What a dial gives back: a connected, non-blocking stream socket the
    ## caller now owns, or -1 and the reason.
    fd*: cint
    code*: int

  DialStream* = proc (context: pointer; destination: Endpoint; deadline: Deadline;
                      tok: nil CancelToken): Dialed {.nimcall, passive.}

  Dialer* = object
    ## `context` belongs to whoever made the dialer and must outlive every
    ## dial through it. A zeroed `Dialer` is one nobody set: `isSet` is false
    ## and a dial through it fails with `InvalidInput`.
    context*: nil pointer
    stream*: nil DialStream

  DirectDialer* = object
    ## Connect from this machine. Names are resolved here, and each address
    ## is tried in turn within one budget.
    noDelay*: bool
    timeoutMs*: int     ## for resolving and connecting together
    device*: string     ## leave through this interface ("": the routing table decides)
    mark*: uint32       ## Linux routing mark (0: none; needs CAP_NET_ADMIN)

proc prepareDirect(fd: cint; context: pointer): bool {.nimcall.} =
  let d = cast[ptr DirectDialer](context)
  result = true
  if d.device.len > 0 and not bindToDevice(fd, d.device): result = false
  if result and d.mark != 0 and not setMark(fd, d.mark): result = false

proc directStream(context: pointer; destination: Endpoint; deadline: Deadline;
                  tok: nil CancelToken): Dialed {.nimcall, passive.} =
  let d = cast[ptr DirectDialer](context)
  result = Dialed(fd: -1, code: InvalidInput)
  retain(tok)
  defer: release(tok)
  let until = earlier(deadline, afterMs(d.timeoutMs))
  var addrs {.noinit.}: array[MaxAddrs, SockAddrBuf]
  var n = endpointAddrs(destination, addrs)
  let named = n == 0 and destination.kind == epName
  var host = ""
  if named:
    host = hostString(destination)
    n = resolveAsync(host, destination.port, SOCK_STREAM, 0.cint,
                     resolveBuffer(addrs), until, tok)
    if n <= 0:
      result.code = if n < 0: n else: DnsNoAddresses
      return
  elif n == 0:
    return
  var i = 0
  while i < n and i < addrs.len:
    if cancelled(tok):
      result.code = ECancelled
      break
    var pending = false
    var error = 0
    let fd = startConnect(addr addrs[i], d.noDelay, pending, error, prepareDirect, context)
    if fd < 0:
      result.code = error
    else:
      var outcome = 0
      if pending: parkConnectOutcome(fd, until, tok, outcome)
      if outcome == 0 and not cancelled(tok):
        result = Dialed(fd: fd, code: 0)
        return
      closeFd(fd)
      result.code = if cancelled(tok): ECancelled else: outcome
    i = i + 1
  # A name whose every address refused may have moved: ask again next time.
  if named: forgetHost(host, SOCK_STREAM, 0.cint)

proc dialer*(d: ptr DirectDialer): Dialer =
  ## `d` must stay where it is for as long as the dialer is used.
  Dialer(context: d, stream: directStream)

proc isSet*(d: Dialer): bool {.inline.} = d.stream != nil and d.context != nil

proc dialStream*(d: Dialer; destination: Endpoint; deadline: Deadline = never;
                 tok: nil CancelToken = nil): Dialed {.passive.} =
  ## Connect to `destination` the way this dialer does it.
  let how = d.stream
  let context = d.context
  if how == nil or context == nil: result = Dialed(fd: -1, code: InvalidInput)
  else: result = how(context, destination, deadline, tok)
