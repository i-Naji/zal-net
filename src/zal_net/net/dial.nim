## Dialing: connect to the first reachable address, parking in the enclosing
## passive proc.

import zal_net/rt
import zal_net/raw/io
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/net/dns
import zal_net/rt/cancel
import zal_net/private/core/iocancel

template dialInline*(addrs: var array[MaxAddrs, SockAddrBuf]; n: int; noDelay: bool;
                     timeoutMs: int; outFd: var cint; deadline: Deadline = never;
                     tok: nil CancelToken = nil) =
  ## Connect to the first reachable address, parking in the enclosing
  ## passive proc: no extra frame and no pool round trip per dial.
  block:
    outFd = -1
    let dialToken = tok
    retain(dialToken)
    let dialDeadline = earlier(deadline, afterMs(timeoutMs))
    var dialPending = false
    var dialOk = false
    var di = 0
    while n <= addrs.len and di < n and not cancelled(dialToken):
      let dialFd = startConnect(addr addrs[di], noDelay, dialPending)
      if dialFd >= 0:
        if dialPending: parkConnectCancellable(dialFd, dialDeadline, dialToken, dialOk)
        if (not dialPending or dialOk) and not cancelled(dialToken):
          outFd = dialFd
          break
        closeFd(dialFd)
      di = di + 1
    release(dialToken)

proc dialHost*(host: string; port: uint16; noDelay = true; timeoutMs = 10_000;
               deadline = never; tok: nil CancelToken = nil): cint {.passive.} =
  retain(tok)
  defer: release(tok)
  if cancelled(tok): return -1
  let endAt = earlier(deadline, afterMs(timeoutMs))
  var addrs {.noinit.}: array[MaxAddrs, SockAddrBuf]
  let n = resolveAsync(host, port, SOCK_STREAM, 0.cint,
                       resolveBuffer(addrs), endAt, tok)
  var fd: cint = -1
  dialInline(addrs, n, noDelay, timeoutMs, fd, endAt, tok)
  result = fd

proc dialTcp*(host: string; port: uint16; deadline = never;
              tok: nil CancelToken = nil): cint {.passive.} =
  result = dialHost(host, port, true, deadline = deadline, tok = tok)
