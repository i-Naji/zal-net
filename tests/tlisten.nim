## Listeners at run time: closeListener ends every accept loop on one
## listener, frees its port and registry slot, and new listeners and accept
## loops can start while the loops run. Task submission.
import std/assertions
import std/syncio
import std/atomics
import zal_net/rt
import zal_net/raw/io
import zal_net/private/core/waitq
import zal_net/raw/socket
import zal_net/net/dial

var gAccepted: int   # atomic
var gExited: int     # atomic
var gOnLoop: int     # atomic

proc acceptor(fd: cint) {.passive.} =
  var res = 0
  while true:
    let c = acceptNow(fd)
    if c >= 0:
      discard atomicFetchAdd(gAccepted, 1, moAcquireRelease)
      closeFdRaw(cint(c))
    elif c == AcceptClosed:
      break
    elif c == AcceptAgain:
      parkAccept(fd, res)
    elif c == AcceptBusy:
      parkUntil(afterMs(10))
  discard atomicFetchAdd(gExited, 1, moAcquireRelease)

proc mark() {.passive.} =
  discard atomicFetchAdd(gOnLoop, 1, moAcquireRelease)

proc connectMany(port: uint16; n: int) {.passive.} =
  let before = atomicLoad(gAccepted, moAcquire)
  var i = 0
  while i < n:
    let c = dialTcp("127.0.0.1", port)
    assert c >= 0
    closeFd(c)
    i = i + 1
  var spins = 0
  while atomicLoad(gAccepted, moAcquire) < before + n and spins < 2000:
    sleepMs(1)
    spins = spins + 1
  assert atomicLoad(gAccepted, moAcquire) == before + n

proc main() {.passive.} =
  let per = 1
  let first = tryListenTcp(0, bindAddr = "127.0.0.1")
  assert first.ok
  let port = localPort(first.fd)
  assert port != 0
  spawnTask acceptor(first.fd)
  connectMany(port, 10)
  assert closeListener(first.fd) == wrReady
  assert atomicLoad(gExited, moAcquire) == per
  assert listenerSlot(first.fd) < 0
  assert dialTcp("127.0.0.1", port) < 0
  echo "PASS closeListener: ", per, " accept loops ended, port refused"

  # The same port again, with accept loops started at run time.
  let again = tryListenTcp(port, bindAddr = "127.0.0.1")
  assert again.ok
  spawnTask acceptor(again.fd)
  connectMany(port, 5)
  assert closeListener(again.fd) == wrReady
  assert atomicLoad(gExited, moAcquire) == 2 * per
  echo "PASS rebind the port and accept again"

  # More cycles than registry slots: slots and ports are reused.
  var k = 0
  while k < 100:
    let l = tryListenTcp(port, bindAddr = "127.0.0.1")
    assert l.ok
    spawnTask acceptor(l.fd)
    if k mod 10 == 0: connectMany(port, 1)
    assert closeListener(l.fd) == wrReady
    k = k + 1
  assert atomicLoad(gExited, moAcquire) == 102 * per
  echo "PASS 100 open/close cycles"

  assert closeListener(12345.cint) == wrClosed
  echo "PASS unknown listener"

  # A UDP port is never shared (no SO_REUSEADDR on UDP: Linux would split
  # its datagrams between the sockets).
  let u = tryListenUdp(0, bindAddr = "127.0.0.1")
  assert u.ok
  let u2 = tryListenUdp(localPort(u.fd), bindAddr = "127.0.0.1")
  assert not u2.ok
  discard closeRaw(u.fd)
  echo "PASS a UDP port is not shared"

  var j = 0
  while j < 8:
    spawnTask(mark())
    j = j + 1
  var spins = 0
  while atomicLoad(gOnLoop, moAcquire) < 8 and spins < 1000:
    sleepMs(1)
    spins = spins + 1
  assert atomicLoad(gOnLoop, moAcquire) == 8
  echo "PASS task submission"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
