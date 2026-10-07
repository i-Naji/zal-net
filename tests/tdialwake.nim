{.feature: "assumeSync".}
import zal_net/net/endpointdial
## A dial woken before its connect completes keeps waiting: it never hands
## back a socket that is not connected. (On Windows the shutdown hook
## resumes parked tasks by descriptor number, later: a new socket may
## already have that number.) The connect is kept pending by a listener
## whose queue is full; where a full queue refuses at once (Windows), the
## test has nothing to check.
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/net/[sockaddr, endpoint, dial], zal_net/raw/socket
import zal_net/private/sys/sock

var dialed: cint = -2
var dialConnected = false

proc dialer(port: uint16) {.passive.} =
  let fd = dialHost("127.0.0.1", port, true, 2500)
  if fd >= 0:
    var ss = default(SockAddrBuf)
    var len = cuint(sizeof(ss))
    dialConnected = sockGetpeername(fd, addr ss.ss, addr len) == 0
    closeFd(fd)
  dialed = fd

proc main() {.passive.} =
  let l = tryListenTcp(0, backlog = 1, bindAddr = "127.0.0.1")
  if not l.ok: quit "FAIL listen"
  let port = localPort(l.fd)
  var d = default(Endpoint)
  if not parseHostPort("127.0.0.1:" & $port, d): quit "FAIL endpoint"
  var addrs {.noinit.}: array[MaxAddrs, SockAddrBuf]
  if endpointAddrs(d, addrs) != 1: quit "FAIL addrs"
  var fill: seq[cint] = @[]
  for i in 0 ..< 8:                                   # the accept queue, full
    var pending = false
    let fd = startConnect(addr addrs[0], true, pending)
    if fd >= 0: fill.add fd
  sleepMs(200)
  spawnTask dialer(port)
  sleepMs(300)
  if dialed != -2:
    echo "SKIP a full accept queue refused the connect at once (nothing pending to wake)"
    quit 0
  # Wakes with no connect done: what a stale wake by descriptor number is.
  var fd: cint = 0
  while fd < 512:
    discard nudgeFd(fd)
    fd = fd + 1
  var waited = 0
  while dialed == -2 and waited < 5000:
    sleepMs(20)
    waited = waited + 20
  if dialed == -2: quit "FAIL the dial never ended"
  if dialed >= 0 and not dialConnected: quit "FAIL a woken dial returned a socket that is not connected"
  echo "PASS a dial woken early keeps waiting (", (if dialed >= 0: "connected" else: "timed out"), ")"
  for f in fill: closeFd(f)
  discard closeListener(l.fd, acceptors = 0)
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
