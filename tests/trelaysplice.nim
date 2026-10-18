{.feature: "assumeSync".}
## Plain <-> plain over TCP, 16 MiB each way with half-close: on Linux the
## bulk goes through splice(2). With -d:nnStreamFaultTest the first splice
## output is refused, and the relay goes on through user space without
## losing what the pipe held.
import std/assertions
import std/syncio
import std/atomics
import zal_net/rt
import zal_net/raw/io
import zal_net/raw/socket
import zal_net/relay
import zal_net/raw/tcp, zal_net/net/address

when defined(linux) and defined(nnStreamFaultTest):
  proc rejectOutput() {.importc: "nn_test_reject_splice_output".}
  proc pending(): cint {.importc: "nn_test_splice_rejection_pending".}

const Total = 16 shl 20

var gOk: int
var gBad: int

proc pat(i, seed: int): byte {.inline.} = byte((i * 131 + seed) and 0xff)

proc writePlain(fd: cint; seed: int) {.passive.} =
  var buf = default(array[65536, byte])
  var sent = 0
  while sent < Total:
    let n = min(buf.len, Total - sent)
    for k in 0 ..< n: buf[k] = pat(sent + k, seed)
    if not writeAll(fd, addr buf[0], n, 5000):
      discard atomicFetchAdd(gBad, 1, moAcquireRelease)
      return
    sent = sent + n
  shutdownWrite(fd)

proc readPlain(fd: cint; seed: int) {.passive.} =
  var buf = default(array[65536, byte])
  var got = 0
  while true:
    let n = waitRead(fd, addr buf[0], buf.len, 5000)
    if n <= 0: break
    for k in 0 ..< n:
      if buf[k] != pat(got + k, seed):
        echo "FAIL byte ", got + k
        discard atomicFetchAdd(gBad, 1, moAcquireRelease)
        return
    got = got + n
  if got == Total: discard atomicFetchAdd(gOk, 1, moAcquireRelease)
  else:
    echo "FAIL got ", got, " of ", Total
    discard atomicFetchAdd(gBad, 1, moAcquireRelease)

proc tcpPair(outer, inner: var cint) {.passive.} =
  var l = listenTcp(0, "127.0.0.1")
  var cl = connect(initSocketAddress(loopback4(), port(l)))
  var sv = accept(l)
  outer = takeNativeHandle(addr cl)
  inner = takeNativeHandle(addr sv)
  closeNow(l)

proc runRelay(c: Conn) {.passive.} =
  startPumps(c)

proc main() {.passive.} =
  let base = liveConnections()
  var o1: cint = -1
  var r1: cint = -1
  var o2: cint = -1
  var r2: cint = -1
  tcpPair(o1, r1)
  tcpPair(o2, r2)
  let c = newConn(5000)
  if c == nil: quit "trelaysplice: no connection block"
  c.fd = r1
  c.up = r2
  c.a.src = r1
  c.a.dst = r2
  c.b.src = r2
  c.b.dst = r1
  when defined(linux) and defined(nnStreamFaultTest): rejectOutput()
  spawnTask runRelay(c)
  spawnTask writePlain(o1, 5)
  spawnTask readPlain(o2, 5)
  spawnTask writePlain(o2, 9)
  spawnTask readPlain(o1, 9)
  var spins = 0
  while atomicLoad(gOk, moAcquire) + atomicLoad(gBad, moAcquire) < 2 and spins < 20_000:
    sleepMs(1)
    spins = spins + 1
  assert atomicLoad(gBad, moAcquire) == 0 and atomicLoad(gOk, moAcquire) == 2
  when defined(linux) and defined(nnStreamFaultTest):
    assert pending() == 0, "the relay never spliced"
    echo "PASS refused splice output: the relay goes on through user space"
  echo "PASS plain <-> plain over TCP, 16 MiB each way, half-close"
  closeFd(o1)
  closeFd(o2)
  spins = 0
  while liveConnections() > base and spins < 2000:
    sleepMs(1)
    spins = spins + 1
  assert liveConnections() == base
  echo "PASS the connection block went back"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
