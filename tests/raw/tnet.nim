## Listen, dial, accept and echo on loopback; numeric parsing; resolveAsync
## and its cache.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/net/dns
import zal_net/net/dial


proc echoOnce(listener: cint) {.passive.} =
  let fd = cint(waitAccept(listener))
  assert fd >= 0
  var buf = default(array[5, byte])
  assert readExact(fd, addr buf[0], 5, 2000)
  assert writeAll(fd, addr buf[0], 5)
  closeFd(fd)

proc main() {.passive.} =
  var sa = default(SockAddrBuf)
  assert parseNumeric("127.0.0.1", 80, AF_INET, sa)
  assert parseNumeric("::1", 80, 0.cint, sa)
  assert not parseNumeric("localhost", 80, 0.cint, sa)
  echo "PASS numeric addresses"

  let listener = tryListenTcp(0, bindAddr = "127.0.0.1")
  assert listener.ok
  let port = localPort(listener.fd)
  assert port != 0
  spawnTask echoOnce(listener.fd)
  let c = dialTcp("127.0.0.1", port)
  assert c >= 0
  var msg = [byte 104, 101, 108, 108, 111]
  assert writeAll(c, addr msg[0], 5)
  var back = default(array[5, byte])
  assert readExact(c, addr back[0], 5, 2000)
  assert back == msg
  closeFd(c)
  echo "PASS listen, dial, accept, echo"

  var addrs = default(array[MaxAddrs, SockAddrBuf])
  let n = resolveAsync("localhost", 443, SOCK_STREAM, 0.cint,
                       cast[ptr UncheckedArray[SockAddrBuf]](addr addrs[0]))
  assert n >= 1
  let t0 = monoNow()
  let m = resolveAsync("LOCALHOST", 443, SOCK_STREAM, 0.cint,
                       cast[ptr UncheckedArray[SockAddrBuf]](addr addrs[0]))
  assert m == n
  assert int64(monoNow()) - int64(t0) < 5_000_000   # a cache hit, no resolver round trip
  echo "PASS resolveAsync and its cache"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
