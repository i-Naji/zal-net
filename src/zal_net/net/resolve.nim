## Async address resolution, separate from address values.
import zal_net/net/[address, sockaddr, dns]
import zal_net/rt
import zal_net/rt/cancel

proc resolve*(host: string; port: uint16; family: cint = 0; sockType = SOCK_STREAM;
              deadline = never; tok: nil CancelToken = nil): seq[SocketAddress] {.passive.} =
  ## The addresses of `host` (a name resolves off the loop, through the
  ## shared cache; a number at once), in the resolver's order. Empty when
  ## it does not resolve. `family`: 0 both, AF_INET or AF_INET6.
  result = @[]
  if cancelled(tok): return
  var addrs {.noinit.}: array[MaxAddrs, SockAddrBuf]
  let n = resolveAsync(host, port, sockType, family, resolveBuffer(addrs), deadline, tok)
  var i = 0
  while i < n:
    result.add SocketAddress(raw: addrs[i])
    i = i + 1

proc resolve4*(host: string; port: uint16; deadline = never;
               tok: nil CancelToken = nil): seq[SocketAddress] {.passive.} =
  result = resolve(host, port, AF_INET, deadline = deadline, tok = tok)

proc resolve6*(host: string; port: uint16; deadline = never;
               tok: nil CancelToken = nil): seq[SocketAddress] {.passive.} =
  result = resolve(host, port, AF_INET6, deadline = deadline, tok = tok)

# -------------------------------------------------------------------- CIDR
