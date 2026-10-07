{.feature: "assumeSync".}
## Streams: a TCP relay (splice on Linux, and the plain path) carries
## 4 MiB each way intact and forwards the half-close; a Unix-to-TCP relay
## (two stream types); a quiet direction outlives its stream's own idle
## limit while the other moves, and the relay ends once both are idle;
## BufReader lines (CRLF, LF, a last line without one, too long), a
## delimited head, then an exact body.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/net/address
import zal_net/raw/tcp
import zal_net/raw/unix
import zal_net/net/stream
import zal_net/rt/sync

import std/envvars
import zal_net/private/sys/sock

proc tmpDir(): string =
  when defined(windows): getEnv("TEMP") & "\\"
  else: "/tmp/"

const Total = 4 * 1024 * 1024

type ReadyStream = object
  remaining: int

proc recvInto(s: ptr ReadyStream; p: pointer; n: int; deadline: Deadline): int {.passive.} =
  result = min(s.remaining, n)
  s.remaining = s.remaining - result

proc sendFrom(s: ptr ReadyStream; p: pointer; n: int; deadline: Deadline): int {.passive.} =
  result = n

proc markReady(done: ptr Event) {.passive.} =
  setEvent(done)

proc checkReadyFairness() {.passive.} =
  # Both operations always complete synchronously: no OS backpressure can
  # accidentally hide a pump that never gives another task a turn.
  var source = ReadyStream(remaining: Total)
  var sink = default(ReadyStream)
  var other = default(Event)
  spawnTask markReady(addr other)
  let copied = copy(addr source, addr sink, splice = false)
  let observed = isSet(addr other)
  while not isSet(addr other):
    discard wait(addr other, never)
  assert copied.bytes == Total and copied.error == 0
  assert observed, "continuously ready copy starved the queued task"
  echo "PASS continuously ready copy gave queued work a turn before EOF"

var gBackend: uint16
var gSplice: bool
var gStats: RelayStats
var gRelays: int

proc echoBack(s: TcpStreamPtr): int {.passive.} =
  ## Echo until EOF, then end our side.
  var buf = default(array[32768, byte])
  while true:
    let n = recv(s, buf)
    if n <= 0: break
    if not writeAll(s, buf.toOpenArray(0, n - 1)): break
  shutdownWrite(s)
  result = 0

proc proxy(s: TcpStreamPtr): int {.passive.} =
  var up = connect(initSocketAddress(loopback4(), gBackend))
  assert up.isOpen
  gStats = relay(s, addr up, splice = gSplice)
  gRelays = gRelays + 1
  close(addr up)
  result = 0

proc proxyUnix(s: UnixStreamPtr): int {.passive.} =
  var up = connect(initSocketAddress(loopback4(), gBackend))
  assert up.isOpen
  gStats = relay(s, addr up)
  gRelays = gRelays + 1
  close(addr up)
  result = 0

proc pattern(i: int): byte {.inline.} = byte((i * 7 + i shr 11) and 0xff)

proc sender(c: TcpStreamPtr) {.passive.} =
  var buf = default(array[65536, byte])
  var sent = 0
  while sent < Total:
    let n = min(buf.len, Total - sent)
    var i = 0
    while i < n:
      buf[i] = pattern(sent + i)
      i = i + 1
    assert writeAll(c, addr buf[0], n)
    sent = sent + n
  shutdownWrite(c)

proc roundTrip[S: ByteStream](c: S) {.passive.} =
  ## Send Total bytes (from a second task), read them all back, then EOF.
  when S is TcpStreamPtr:
    spawnTask sender(c)
  var buf = default(array[65536, byte])
  var got = 0
  while true:
    let n = recvInto(c, addr buf[0], buf.len, never)
    if n == 0: break
    assert n > 0, $n
    var i = 0
    while i < n:
      assert buf[i] == pattern(got + i)
      i = i + 1
    got = got + n
  assert got == Total, $got

proc unixSender(c: UnixStreamPtr) {.passive.} =
  var buf = default(array[65536, byte])
  var sent = 0
  while sent < Total:
    let n = min(buf.len, Total - sent)
    var i = 0
    while i < n:
      buf[i] = pattern(sent + i)
      i = i + 1
    assert writeAll(c, addr buf[0], n)
    sent = sent + n
  shutdownWrite(c)

proc waitRelays(n: int) {.passive.} =
  var i = 0
  while gRelays < n and i < 200:
    parkUntil(afterMs(10))
    i = i + 1
  assert gRelays == n

# --------------------------------------------------------------- idle

var gQuietBackend: uint16

proc quietBack(s: TcpStreamPtr): int {.passive.} =
  ## Reads for a while without answering, then answers once.
  var buf = default(array[256, byte])
  var total = 0
  while total < 12:
    let n = recv(s, buf)
    if n <= 0: return 0
    total = total + n
  discard write(s, "done")
  var k = 0
  while k >= 0:                     # until the relay gives up on us
    k = recv(s, buf)
    if k == 0: break
  result = 0

proc quietProxy(s: TcpStreamPtr): int {.passive.} =
  var up = connect(initSocketAddress(loopback4(), gQuietBackend), streamTimeoutMs = 100)
  assert up.isOpen
  let down = s
  down.timeoutMs = 100              # each stream alone would give up after 100 ms
  gStats = relay(down, addr up, idleMs = 400)
  gRelays = gRelays + 1
  close(addr up)
  result = 0

# ---------------------------------------------------------- BufReader

proc bufServer(s: TcpStreamPtr): int {.passive.} =
  discard write(s, "first\r\nsecond\n\r\nHEAD: x\r\n\r\nbody12345" & "0123456789abcdef" & "\nlast")
  shutdownWrite(s)
  var buf = default(array[16, byte])
  discard recv(s, buf)
  result = 0

proc main() {.passive.} =
  checkReadyFairness()
  var back = listenTcp(0, "127.0.0.1")
  assert back.ok
  gBackend = port(back)
  serve(back, echoBack)
  var front = listenTcp(0, "127.0.0.1")
  serve(front, proxy)

  for sp in [true, false]:
    gSplice = sp
    let before = gRelays
    var c = connect(initSocketAddress(loopback4(), port(front)))
    assert c.isOpen
    roundTrip(addr c)
    close(addr c)
    waitRelays(before + 1)
    assert gStats.aToB.bytes == Total and gStats.bToA.bytes == Total
    assert gStats.aToB.error == 0 and gStats.bToA.error == 0
    echo "PASS TCP relay (", (if sp: "splice where available" else: "plain"),
         "): 4 MiB each way intact, half-close forwarded"

  let upath = tmpDir() & "nn-tstream-" & $getPid() & ".sock"
  var ul = listenUnix(upath)
  assert ul.ok
  serve(ul, proxyUnix)
  var uc = connectUnix(upath)
  assert uc.isOpen
  spawnTask unixSender(addr uc)
  let before = gRelays
  roundTrip(addr uc)
  close(addr uc)
  waitRelays(before + 1)
  assert gStats.aToB.bytes == Total and gStats.bToA.bytes == Total
  discard close(ul)
  echo "PASS Unix-to-TCP relay: 4 MiB each way"

  var qb = listenTcp(0, "127.0.0.1")
  gQuietBackend = port(qb)
  serve(qb, quietBack)
  var qf = listenTcp(0, "127.0.0.1")
  serve(qf, quietProxy)
  var q = connect(initSocketAddress(loopback4(), port(qf)))
  assert q.isOpen
  var i = 0
  while i < 6:                      # 300 ms of client traffic; the way back stays quiet
    parkUntil(afterMs(50))
    discard write(addr q, "ab")
    i = i + 1
  var reply = default(array[4, byte])
  assert readExactly(addr q, reply)
  let t0 = monoNow()
  let before2 = gRelays
  waitRelays(before2 + 1)
  let waited = (int64(monoNow()) - int64(t0)) div 1_000_000
  assert gStats.aToB.error == IoTimedOut or gStats.bToA.error == IoTimedOut
  assert waited >= 250 and waited < 1500, $waited
  close(addr q)
  echo "PASS a quiet direction outlived its 100 ms stream limit; idle after ", waited, " ms"

  var bl = listenTcp(0, "127.0.0.1")
  serve(bl, bufServer)
  var bs = connect(initSocketAddress(loopback4(), port(bl)))
  var r = initBufReader(addr bs, 64)
  var line = ""
  assert readLine(addr r, addr line) == 5 and line == "first"
  let pending = buffered(addr r)
  assert pending > 0
  assert readLine(addr r, addr line, deadline = afterMs(-1)) == IoTimedOut
  assert buffered(addr r) == pending
  var expiredByte = 0'u8
  assert recvInto(addr r, addr expiredByte, 1, deadline = afterMs(-1)) == IoTimedOut
  assert buffered(addr r) == pending
  assert readLine(addr r, addr line) == 6 and line == "second"
  assert readLine(addr r, addr line) == 0 and line == ""
  let h = readUntil(addr r, "\r\n\r\n")
  assert h == 11, $h
  assert peek(addr r)[0] == byte('H')
  consume(addr r, h)
  var body = default(array[25, byte])
  assert readExactly(addr r, addr body[0], body.len)
  assert body[0] == byte('b') and body[24] == byte('f')
  assert readLine(addr r, addr line) == 0          # the "\n" after the body
  assert readLine(addr r, addr line) == 4 and line == "last"
  assert readLine(addr r, addr line) == StreamEof
  close(addr bs)
  var bs2 = connect(initSocketAddress(loopback4(), port(bl)))
  var r2 = initBufReader(addr bs2, 64)
  assert readLine(addr r2, addr line, maxLen = 3) == TooLong
  close(addr bs2)
  echo "PASS BufReader: CRLF and LF lines, a delimited head, an exact body, a last line, too long"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
