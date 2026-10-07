{.feature: "assumeSync".}
## TCP: an echo server on every loop (openArray sugar, half-close) for 50
## clients x 64 KiB; the idle limit and an operation deadline; a refused
## connect and a freed port; accept without serve; vectored I/O; Happy
## Eyeballs to "localhost" when only IPv4 listens; `interrupt` and a
## cancelled token wake a reader parked on the same socket (from another
## loop too).
import std/assertions
import std/syncio
import std/atomics
import zal_net/rt
import zal_net/raw/io
import zal_net/net/sockaddr
import zal_net/net/address
import zal_net/raw/tcp
import zal_net/rt/cancel

var gDone, gFailed: int

proc echoHalfClose(s: TcpStreamPtr): int {.passive.} =
  var buf = default(array[8192, byte])
  while true:
    let n = recv(s, buf)
    if n <= 0: break
    if not writeAll(s, buf.toOpenArray(0, n - 1)): break
  shutdown(s, shutWrite)
  result = 0

proc silent(s: TcpStreamPtr): int {.passive.} =
  var b = default(array[64, byte])
  while recv(s, b) > 0: discard
  result = 0

proc client(port: uint16; seed: int) {.passive.} =
  var s = connect("127.0.0.1", port)
  if not s.isOpen:
    discard atomicFetchAdd(gFailed, 1, moRelaxed)
    return
  var data = newSeq[byte](65536)
  var i = 0
  while i < data.len:
    data[i] = byte((i * 7 + seed) and 0xff)
    i = i + 1
  var ok = writeAll(addr s, data)
  shutdown(addr s, shutWrite)
  var back = newSeq[byte](65536)
  ok = ok and readExactly(addr s, back)
  var tail = default(array[1, byte])
  ok = ok and recv(addr s, tail) == 0
  ok = ok and back == data
  close(addr s)
  if ok: discard atomicFetchAdd(gDone, 1, moRelaxed)
  else: discard atomicFetchAdd(gFailed, 1, moRelaxed)

proc waitCount(p: ptr int; want, ms: int): bool {.passive.} =
  var waited = 0
  while atomicLoad(p[], moRelaxed) < want and waited < ms:
    sleepMs(5)
    waited = waited + 5
  result = atomicLoad(p[], moRelaxed) >= want

proc elapsedMs(t0: Deadline): int64 = (int64(monoNow()) - int64(t0)) div 1_000_000

var gParked: int     # atomic: readers that returned

proc parkedReader(s: TcpStreamPtr) {.passive.} =
  var b = default(array[16, byte])
  let n = recvInto(s, addr b[0], b.len, afterMs(5000))
  assert n <= 0 and n != IoTimedOut, $n     # woken by the shutdown, not the deadline
  discard atomicFetchAdd(gParked, 1, moAcquireRelease)

proc main() {.passive.} =
  var l = listenTcp(0, "127.0.0.1")
  assert l.ok and l.port > 0, l.error
  serve(l, echoHalfClose)
  var k = 0
  while k < 50:
    spawnTask client(l.port, k)
    k = k + 1
  assert waitCount(addr gDone, 50, 20_000), $gDone & "/" & $gFailed
  echo "PASS 50 clients x 64 KiB through a TCP echo server on every loop, half-closing"

  var q = listenTcp(0, "127.0.0.1")
  serve(q, silent)
  var s = connect("127.0.0.1", q.port, streamTimeoutMs = 200)
  var b = default(array[16, byte])
  var t0 = monoNow()
  assert recv(addr s, b) == IoTimedOut and elapsedMs(t0) >= 150
  s.timeoutMs = 0
  t0 = monoNow()
  assert recvInto(addr s, addr b[0], b.len, afterMs(100)) == IoTimedOut and elapsedMs(t0) >= 80
  close(addr s)
  echo "PASS the idle limit and an operation deadline end a read"

  assert close(q)
  assert not connect("127.0.0.1", q.port, timeoutMs = 1000).isOpen
  var again = listenTcp(q.port, "127.0.0.1")
  assert again.ok
  closeNow(again)
  echo "PASS a closed listener refuses and frees its port"

  var m = listenTcp(0, "127.0.0.1")
  spawnTask client(m.port, 99)
  var a = accept(m)
  assert a.isOpen and isLoopback(ip(remoteAddress(a))) and port(localAddress(a)) == m.port
  var buf = newSeq[byte](65536)
  while true:
    let n = recv(addr a, buf)
    if n <= 0: break
    assert writeAll(addr a, buf.toOpenArray(0, n - 1))
  shutdown(addr a, shutWrite)
  assert waitCount(addr gDone, 51, 5000)
  close(addr a)
  closeNow(m)
  echo "PASS accept without serve; local and remote addresses"

  # Vectored I/O through the echo server.
  var v = connect("127.0.0.1", l.port)
  var one = [byte 1, 2, 3]
  var two = [byte 4, 5, 6, 7]
  var iov = [IoVec(iov_base: addr one[0], iov_len: 3), IoVec(iov_base: addr two[0], iov_len: 4)]
  assert sendVectored(addr v, addr iov[0], 2) == 7
  shutdown(addr v, shutWrite)
  var r1 = default(array[2, byte])
  var r2 = default(array[5, byte])
  var riov = [IoVec(iov_base: addr r1[0], iov_len: 2), IoVec(iov_base: addr r2[0], iov_len: 5)]
  var got = 0
  while got < 7:
    let n = recvVectored(addr v, addr riov[0], 2)
    assert n > 0
    got = got + n
    if got < 7:   # a short read: take the rest plainly
      assert readExactly(addr v, addr r2[got - 2], 7 - got)
      got = 7
  assert r1 == [byte 1, 2] and r2 == [byte 3, 4, 5, 6, 7]
  close(addr v)
  echo "PASS vectored send and receive"

  # Happy Eyeballs: "localhost" may resolve to ::1 first; only IPv4 listens.
  var h = listenTcp(0, "127.0.0.1")
  serve(h, echoHalfClose)
  t0 = monoNow()
  var e = connect("localhost", h.port, timeoutMs = 5000)
  assert e.isOpen
  let took = elapsedMs(t0)
  assert write(addr e, "hi")
  shutdown(addr e, shutWrite)
  var hb = default(array[2, byte])
  assert readExactly(addr e, hb)
  close(addr e)
  echo "PASS Happy Eyeballs reaches the IPv4 listener through \"localhost\" (", took, " ms)"

  # An IPv4-mapped address reaches the IPv4 listener: the socket must be
  # dual-stack (Windows makes IPv6 sockets IPv6-only by default).
  var mapped = connect("::ffff:127.0.0.1", h.port, timeoutMs = 5000)
  assert mapped.isOpen
  assert write(addr mapped, "hi")
  shutdown(addr mapped, shutWrite)
  var mb = default(array[2, byte])
  assert readExactly(addr mapped, mb)
  close(addr mapped)
  echo "PASS an IPv4-mapped address reaches the IPv4 listener"

  # Interrupting a socket wakes a reader parked on it, on this loop or
  # another. Windows' std backend cannot (see the manual, chapter 7).
  when not defined(windows):
    var il = listenTcp(0, "127.0.0.1")
    var c1 = connect(initSocketAddress(loopback4(), il.port))
    var s1 = accept(il)
    var c2 = connect(initSocketAddress(loopback4(), il.port))
    var s2 = accept(il)
    spawnTask parkedReader(addr s1)                 # this loop
    spawnTask(parkedReader(addr s2)) # another loop when available
    sleepMs(50)
    t0 = monoNow()
    interrupt(addr s1)
    let tok = newCancelToken()
    adoptFd(tok, nativeHandle(s2))
    cancel(tok)
    assert waitCount(addr gParked, 2, 2000)
    let woke = elapsedMs(t0)
    release(tok)
    close(addr s1)
    close(addr s2)
    close(addr c1)
    close(addr c2)
    closeNow(il)
    echo "PASS interrupt and a cancelled token wake parked readers (", woke, " ms)"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
