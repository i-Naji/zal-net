## Lifecycle: stopAccepting ends accept loops (AcceptClosed), and
## requestStop makes drainRuntime return.
import std/assertions
import std/syncio
import std/atomics
import zal_net/rt
import zal_net/raw/io
import zal_net/raw/socket

var gAcceptorsDone: int   # atomic
var gStopAt: int64

proc acceptor(fd: cint) {.passive.} =
  var res = 0
  while true:
    let c = acceptNow(fd)
    if c >= 0:
      closeFd(cint(c))
    elif c == AcceptClosed:
      break
    elif c == AcceptAgain:
      parkAccept(fd, res)
    elif c == AcceptBusy:
      parkUntil(afterMs(10))
  discard atomicFetchAdd(gAcceptorsDone, 1, moAcquireRelease)

proc stopper() {.passive.} =
  sleepMs(50)
  stopAccepting()
  sleepMs(100)
  gStopAt = int64(monoNow())
  requestStop()

initRuntime()
let listener = tryListenTcp(0, bindAddr = "127.0.0.1")
assert listener.ok
spawnTask acceptor(listener.fd)
spawnTask stopper()
drainRuntime()
let lag = int64(monoNow()) - gStopAt
let expected = 1
echo "acceptors done ", atomicLoad(gAcceptorsDone, moAcquire), " of ", expected, ", lag ", lag div 1_000_000, " ms"
assert atomicLoad(gAcceptorsDone, moAcquire) == expected
assert lag < 1_000_000_000
echo "PASS stopAccepting ended ", expected, " accept loops; drainRuntime returned ", lag div 1_000_000, " ms after requestStop"
quit 0
