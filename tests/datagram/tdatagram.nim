{.feature: "assumeSync".}
import zal_net/codecs/socksaddr
## The datagram engine end to end, with no framework: tunnel listeners
## over IPv4 and IPv6, a domain target (datagrams queued while it
## resolves), a blocking route, route invalidation, a toy codec with owners
## (exact byte counts; a changed generation ends the association on its
## next datagram or on the tick), a burst of equal datagrams (GSO runs on
## Linux), 10k associations churning through expiry, removing a listener
## and stopping.
import std/assertions
import std/syncio
import std/atomics
import zal_net/rt
import zal_net/raw/io
import zal_net/private/sys/posix
import zal_net/private/sys/threads
import zal_net/private/sys/sock
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/net/endpoint
import zal_net/datagram

# -------------------------------------------------------------- toy codec
# Datagram: [owner index][SOCKS destination][payload]; reply: [SOCKS source][payload].

var gOwners = [0, 1]            # what an association's `owner` points at
var gOwnerGen = [0, 0]          # atomic: bump to end an owner's associations
var gUp = [0'i64, 0]            # atomic: payload bytes per owner (onBytes)
var gDown = [0'i64, 0]
var gEndWhy = [-1, -1]          # atomic: how an owner's last association ended
var gRoutes = 0                 # atomic: route hook calls
var gEndedId = [0'u64, 0]       # atomic: the id of each owner's last ended association
var gLateBytes = 0              # atomic: onBytes calls after their association's onEnd

proc ownerIdx(a: ptr Assoc): int = cast[ptr int](a.owner)[]

proc toyOpen(e: ptr DatagramEngine; ib: int; p: ptr UncheckedArray[byte]; n: int;
             peer: ptr SockaddrStorage; peerLen: cuint; now: int64; pkt: var Packet): bool =
  if n < 2 or int(p[0]) >= gOwners.len: return false
  var v = default(SocksAddrView)
  if not viewSocksAddr(p, 1, n, v): return false
  let id = peerKey(peer, peerLen)
  var slot = lookupAssoc(e, ib, id)
  if slot < 0:
    slot = claimAssoc(e, ib, id, now)
    if slot < 0: return false
    let a = assocAt(e, slot)
    setPeer(a, peer, peerLen)
    a.owner = addr gOwners[int(p[0])]
    a.ownerGen = atomicLoad(gOwnerGen[int(p[0])], moAcquire)
  pkt.slot = slot
  pkt.dst = endpointView(p, v)
  pkt.pay = cast[ptr UncheckedArray[byte]](addr p[1 + v.used])
  pkt.payLen = n - 1 - v.used
  result = true

proc toyReply(e: ptr DatagramEngine; slot: int; src: EndpointView;
              pay: ptr UncheckedArray[byte]; payLen: int; outp: ptr UncheckedArray[byte]; outCap: int;
              now: int64): int =
  let srcLen = encodeSocksAddr(src, outp, outCap)
  if srcLen == 0 or payLen > outCap - srcLen: return 0
  if payLen > 0: copyMem(addr outp[srcLen], addr pay[0], payLen)
  result = srcLen + payLen

var gToyCodec = ListenerCodec(open: toyOpen, sealReply: toyReply, replyOverhead: MaxSocksAddr)

# ------------------------------------------------------------------ hooks
# The routing and accounting a framework would supply: listener 3 blocks,
# the rest go direct; owners' generations decide `alive`.

proc hRoute(e: ptr DatagramEngine; a: ptr Assoc; dest: ptr Endpoint; resolved: bool;
            addrs: ptr UncheckedArray[SockAddrBuf]; nAddrs: int; ch: var LegChoice): RouteResult =
  discard atomicFetchAdd(gRoutes, 1, moRelaxed)
  if a.inTag == 3: ch.kind = addr gBlockLeg
  result = rrDone

proc hAlive(e: ptr DatagramEngine; a: ptr Assoc; owner: pointer): bool =
  a.ownerGen == atomicLoad(gOwnerGen[cast[ptr int](owner)[]], moAcquire)

proc hBytes(e: ptr DatagramEngine; a: ptr Assoc; up, down: int64) =
  if a.owner == nil: return
  if a.id == atomicLoad(gEndedId[ownerIdx(a)], moAcquire):
    discard atomicFetchAdd(gLateBytes, 1, moRelaxed)   # the owner may be gone by now
  discard atomicFetchAdd(gUp[ownerIdx(a)], up, moRelaxed)
  discard atomicFetchAdd(gDown[ownerIdx(a)], down, moRelaxed)

proc hEnd(e: ptr DatagramEngine; a: ptr Assoc; why: int) =
  if a.owner != nil:
    atomicStore(gEndedId[ownerIdx(a)], a.id, moRelease)
    atomicStore(gEndWhy[ownerIdx(a)], why, moRelease)

var gHooks = EngineHooks(route: hRoute, alive: hAlive, onBytes: hBytes, onEnd: hEnd)

# ------------------------------------------------------------ echo server
# Replies with the payload and the sender's port (2 bytes), so a client
# sees when its association got a new socket.

var gEchoFd: cint
var gEchoStop: int      # atomic
var gEchoDone: int      # atomic
var gEchoCount: int     # atomic: datagrams echoed
var gEchoHold, gEchoWaiting: int # atomic

proc echoMain(arg: nil pointer) {.nimcall.} =
  var buf = newSeq[byte](70000)
  while atomicLoad(gEchoStop, moAcquire) == 0:
    sleepUs(1000)
    while true:
      var sa = default(SockAddrBuf)
      var sl = cuint(sizeof(SockaddrStorage))
      let n = sockRecvfrom(gEchoFd, addr buf[0], csize_t(65000), 0, addr sa.ss, addr sl)
      if n < 0: break
      let raw = cast[ptr UncheckedArray[byte]](addr sa.ss)
      buf[n] = raw[2]
      buf[n + 1] = raw[3]
      if atomicLoad(gEchoHold, moAcquire) != 0:
        atomicStore(gEchoWaiting, 1, moRelease)
        while atomicLoad(gEchoHold, moAcquire) != 0: sleepUs(1000)
      discard sockSendto(gEchoFd, addr buf[0], csize_t(n + 2), 0, addr sa.ss, sl)
      discard atomicFetchAdd(gEchoCount, 1, moRelaxed)
  atomicStore(gEchoDone, 1, moRelease)

# ------------------------------------------------------------------ helpers

proc addrOf(host: string; port: uint16; family: cint): SockAddrBuf =
  result = default(SockAddrBuf)
  assert parseNumeric(host, port, family, result)

proc sendDg(fd: cint; to: SockAddrBuf; data: openArray[byte]) =
  let n = sockSendto(fd, unsafeAddr data[0], csize_t(data.len), 0, unsafeAddr to.ss, to.len)
  assert n == data.len

proc recvDg(fd: cint; buf: var seq[byte]; timeoutMs: int): int =
  ## A datagram's length, or -1 when none came in time.
  var waited = 0
  while true:
    let n = sockRecvfrom(fd, addr buf[0], csize_t(buf.len), 0, nil, nil)
    if n >= 0: return n
    if waited >= timeoutMs: return -1
    sleepUs(int(1000))
    waited = waited + 1

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  var i = 0
  while i < s.len:
    result[i] = byte(s[i])
    i = i + 1

proc textOf(b: seq[byte]; lo, hi: int): string =
  result = ""
  var i = lo
  while i < hi:
    result.add char(b[i])
    i = i + 1

proc portAt(b: seq[byte]; at: int): int = (int(b[at]) shl 8) or int(b[at + 1])

proc waitFor(what: proc (): bool {.nimcall.}; ms: int): bool =
  var waited = 0
  while not what() and waited < ms:
    sleepUs(int(1000))
    waited = waited + 1
  result = what()

var gEngine: nil ptr DatagramEngine
proc noAssocs(): bool =
  let e = gEngine
  result = e != nil and liveAssocs(e) == 0

proc udpSock(host: string): cint =
  let l = tryListenUdp(0, bindAddr = host)
  assert l.ok
  result = l.fd

# --------------------------------------------------------------------- main

initRuntime()
gEchoFd = udpSock("")               # dual stack: 127.0.0.1 and ::1
let ep = localPort(gEchoFd)
startThread(echoMain, nil)

# Listener ids 0..4, one socket each: tunnels (v4, v6, a name, blocked), toy.
var fds = default(array[5, cint])
fds[0] = udpSock("127.0.0.1")
fds[1] = udpSock("::1")
fds[2] = udpSock("127.0.0.1")
fds[3] = udpSock("127.0.0.1")
fds[4] = udpSock("127.0.0.1")
var ports = default(array[5, uint16])
var k = 0
while k < 5:
  ports[k] = localPort(fds[k])
  k = k + 1

var targets = default(array[4, TunnelTarget])
proc setTarget(t: var TunnelTarget; hostPort: string) =
  var d = default(Endpoint)
  assert parseHostPort(hostPort, d)
  t.destination = d
  assert valid(t.destination)
setTarget(targets[0], "127.0.0.1:" & $ep)
setTarget(targets[1], "[::1]:" & $ep)
setTarget(targets[2], "localhost:" & $ep)
setTarget(targets[3], "127.0.0.1:" & $ep)

let made = newDatagramEngine(natSec = 1, hooks = addr gHooks)
if made == nil: quit "tdatagram: no eng"
let eng: ptr DatagramEngine = made
gEngine = eng
startEngine(eng)
k = 0
while k < 5:
  let m = if k < 4: addListener(eng, k, fds[k], addr tunnelCodec, addr targets[k], int32(k))
          else: addListener(eng, k, fds[k], addr gToyCodec, nil, int32(k))
  assert waitEngineMsg(m, 2000) and m.ok
  releaseEngineMsg(m)
  k = k + 1

var buf = newSeq[byte](70000)

# IPv4: three clients, each answered on its own association.
var clients = default(array[3, cint])
let to4 = addrOf("127.0.0.1", ports[0], AF_INET)
k = 0
while k < 3:
  clients[k] = udpSock("127.0.0.1")
  sendDg(clients[k], to4, bytesOf("hello-" & $k))
  k = k + 1
k = 0
while k < 3:
  let n = recvDg(clients[k], buf, 2000)
  assert n == 7 + 2
  assert textOf(buf, 0, 7) == "hello-" & $k
  k = k + 1
assert liveAssocs(eng) == 3
echo "PASS tunnel over IPv4, one association per client"

# invalidateRoutes: the next datagram routes again; the socket is kept.
proc invalidateCall(e: ptr DatagramEngine; m: ptr EngineMsg) = invalidateRoutes(e)
let routes0 = atomicLoad(gRoutes, moAcquire)
sendDg(clients[0], to4, bytesOf("again"))
assert recvDg(clients[0], buf, 2000) == 5 + 2
let port0 = portAt(buf, 5)
assert atomicLoad(gRoutes, moAcquire) == routes0        # the cached route
let im = newEngineMsg(MsgCall)
im.call = invalidateCall
postEngineMsg(eng, im)
assert waitEngineMsg(im, 2000)
releaseEngineMsg(im)
sendDg(clients[0], to4, bytesOf("again"))
assert recvDg(clients[0], buf, 2000) == 5 + 2
assert atomicLoad(gRoutes, moAcquire) == routes0 + 1    # routed again
assert portAt(buf, 5) == port0                          # the same socket
echo "PASS invalidateRoutes routes again; the association keeps its socket"

# IPv6.
let c6 = udpSock("::1")
sendDg(c6, addrOf("::1", ports[1], AF_INET6), bytesOf("six"))
var n = recvDg(c6, buf, 2000)
assert n == 3 + 2 and textOf(buf, 0, 3) == "six"
echo "PASS tunnel over IPv6"

# A domain target: datagrams sent before the name resolves are queued.
let cd = udpSock("127.0.0.1")
let toD = addrOf("127.0.0.1", ports[2], AF_INET)
k = 0
while k < 3:
  sendDg(cd, toD, bytesOf("dns-" & $k))
  k = k + 1
k = 0
while k < 3:
  n = recvDg(cd, buf, 3000)
  assert n == 5 + 2 and textOf(buf, 0, 5) == "dns-" & $k
  k = k + 1
echo "PASS a domain target resolves off the eng thread; queued datagrams follow"

# A blocking route: nothing reaches the echo server.
let before = atomicLoad(gEchoCount, moRelaxed)
let cb = udpSock("127.0.0.1")
sendDg(cb, addrOf("127.0.0.1", ports[3], AF_INET), bytesOf("blocked"))
assert recvDg(cb, buf, 300) == -1
assert atomicLoad(gEchoCount, moRelaxed) == before
echo "PASS a blocking route drops UDP"


# Owners: the reply names its source; byte counts are exact; a changed
# generation ends an association, on the tick or on its next datagram.
let toToy = addrOf("127.0.0.1", ports[4], AF_INET)
proc toyDg(owner: int; port: uint16; payload: int): seq[byte] =
  result = newSeq[byte](1 + 7 + payload)
  result[0] = byte(owner)
  result[1] = 1'u8
  result[2] = 127
  result[3] = 0
  result[4] = 0
  result[5] = 1
  result[6] = byte(port shr 8)
  result[7] = byte(port and 0xff)
  var i = 0
  while i < payload:
    result[8 + i] = byte(i and 0xff)
    i = i + 1
let ca = udpSock("127.0.0.1")
let cbob = udpSock("127.0.0.1")
k = 0
while k < 4:
  sendDg(ca, toToy, toyDg(0, ep, 100))
  n = recvDg(ca, buf, 2000)
  assert n == 7 + 100 + 2
  assert buf[0] == 1 and buf[1] == 127 and buf[4] == 1 and portAt(buf, 5) == int(ep)
  k = k + 1
sendDg(cbob, toToy, toyDg(1, ep, 10))
assert recvDg(cbob, buf, 2000) == 7 + 10 + 2
discard atomicFetchAdd(gOwnerGen[1], 1, moAcquireRelease)   # bob's, while idle
sleepUs(int(1_500_000))       # a tick: bob's ends as kicked; bytes counted
assert atomicLoad(gUp[0], moAcquire) == 400 and atomicLoad(gDown[0], moAcquire) == 408
assert atomicLoad(gUp[1], moAcquire) == 10 and atomicLoad(gDown[1], moAcquire) == 12
echo "PASS onBytes counts payload bytes per owner"
assert atomicLoad(gEndWhy[1], moAcquire) == EndKicked
echo "PASS a changed generation ends an idle association on the tick"

sendDg(ca, toToy, toyDg(0, ep, 100))          # a fresh association for alice
assert recvDg(ca, buf, 2000) == 7 + 100 + 2
let legPort = portAt(buf, 7 + 100)
discard atomicFetchAdd(gOwnerGen[0], 1, moAcquireRelease)
sendDg(ca, toToy, toyDg(0, ep, 100))          # the association ends on this datagram (dropped),
discard recvDg(ca, buf, 300)                  # or on a tick run just before it (a new one answers)
assert atomicLoad(gEndWhy[0], moAcquire) == EndKicked
sendDg(ca, toToy, toyDg(0, ep, 100))
assert recvDg(ca, buf, 2000) == 7 + 100 + 2
assert portAt(buf, 7 + 100) != legPort        # a new association, a new socket
echo "PASS a changed generation ends the association on its next datagram"
assert atomicLoad(gLateBytes, moAcquire) == 0
echo "PASS an association's bytes are all reported before it ends"

# A burst of equal datagrams (one GSO run on Linux) all arrive.
let cg = udpSock("127.0.0.1")
var big = newSeq[byte](1200)
k = 0
while k < 50:
  big[0] = byte(k)
  sendDg(cg, to4, big)
  k = k + 1
var got = 0
var seen = default(array[50, bool])
while got < 50:
  n = recvDg(cg, buf, 2000)
  if n < 0: break
  assert n == 1200 + 2
  seen[int(buf[0])] = true
  got = got + 1
assert got == 50
echo "PASS a burst of 50 datagrams comes back whole"

# Hold a destination reply until the consumer pauses across its idle deadline.
proc echoWaiting(): bool = atomicLoad(gEchoWaiting, moAcquire) != 0
proc pauseForQueuedReply(e: ptr DatagramEngine; m: ptr EngineMsg) =
  atomicStore(gEchoHold, 0, moRelease)
  sleepUs(2_100_000)
let delayedClient = udpSock("127.0.0.1")
atomicStore(gEchoHold, 1, moRelease)
sendDg(delayedClient, to4, bytesOf("queued"))
assert waitFor(echoWaiting, 2000)
let pauseMessage = newEngineMsg(MsgCall)
pauseMessage.call = pauseForQueuedReply
postEngineMsg(eng, pauseMessage)
assert waitEngineMsg(pauseMessage, 5000)
releaseEngineMsg(pauseMessage)
assert recvDg(delayedClient, buf, 5000) == 8
discard closeRaw(delayedClient)
echo "PASS queued replies survive a delayed idle scan"

# 10k associations through expiry (NAT timeout 1 s here).
var soft = 0
var hard = 0
discard fdLimits(soft, hard)
let cap = max(200, min(4000, soft div 2 - 200))
let round = min(250, cap div 2)
echo "  churn: fd limit ", soft, "/", hard, ", at most ", cap, " live, rounds of ", round
var total = 0
var peak = 0
while total < 10_000:
  if liveAssocs(eng) + round > cap:
    if not waitFor(noAssocs, 5000):
      echo "  still live after 5 s: ", liveAssocs(eng), " (", total, " so far)"
      assert false
  var batch = newSeq[cint](round)
  let echoedBefore = atomicLoad(gEchoCount, moRelaxed)
  var i = 0
  while i < round:
    batch[i] = udpSock("127.0.0.1")
    sendDg(batch[i], to4, bytesOf("c"))
    i = i + 1
  i = 0
  var lost = 0
  while i < round:
    if recvDg(batch[i], buf, 3000) != 3: lost = lost + 1
    discard closeRaw(batch[i])
    i = i + 1
  if lost > 0:
    echo "  ", lost, " of ", round, " replies missing (", total, " so far, ", liveAssocs(eng), " live, ",
         atomicLoad(gEchoCount, moRelaxed) - echoedBefore, " echoed)"
    assert false
  total = total + round
  peak = max(peak, liveAssocs(eng))
assert waitFor(noAssocs, 5000)
echo "PASS ", total, " associations churned (peak ", peak, " live), all expired"

# Removing a listener frees its port at once.
let rm = removeListener(eng, 0)
assert waitEngineMsg(rm, 2000) and rm.ok
releaseEngineMsg(rm)
let again = tryListenUdp(ports[0], bindAddr = "127.0.0.1")
assert again.ok
discard closeRaw(again.fd)
echo "PASS a removed listener's port is free"

# Stop.
let st = stopEngine(eng)
assert waitEngineMsg(st, 2000)
releaseEngineMsg(st)
var waited = 0
while not engineStopped(eng) and waited < 7000:
  sleepUs(int(1000))
  waited = waited + 1
assert engineStopped(eng)
assert freeEngine(eng)
atomicStore(gEchoStop, 1, moRelease)
while atomicLoad(gEchoDone, moAcquire) == 0: sleepUs(int(1000))
discard closeRaw(gEchoFd)
echo "PASS the eng stops"

initRuntime()
requestStop()
drainRuntime()
assert runtimeFinished()
