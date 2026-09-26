## Spawning, readiness parks, deadlines, sleeps and yields on one loop;
## interruptFd ends a read parked on a pipe on another loop (loops backend).
import std/[assertions, atomics, ticketlocks]
import zal_net/rt/sync
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/private/sys/posix
import zal_net/private/sys/sock

var order: array[4, int]
var orderLen = 0
var orderLock: TicketLock
var yieldsDone: Event

proc note(v: int) =
  orderLock.acquire()
  order[orderLen] = v
  orderLen = orderLen + 1
  if orderLen == 4: setEvent(addr yieldsDone)
  orderLock.release()

proc yielder(v: int) {.passive.} =
  note(v)
  yieldNow()
  note(v + 10)

proc lateWriter(fd: cint) {.passive.} =
  sleepMs(20)
  var b = 7'u8
  assert writeAll(fd, addr b, 1)

var gInterrupted: int   # result; completion is published independently
var readDone: Event

proc parkedRead(fd: cint) {.passive.} =
  var b = 0'u8
  atomicStore(gInterrupted, 1, moRelease)
  var res = 0
  let deadline = afterMs(5000)
  while true:
    let n = readSome(fd, addr b, 1)
    if n != IoAgain:
      atomicStore(gInterrupted, n, moRelease)
      break
    parkPoll(fd, {evRead}, deadline, res)
    if res <= 0:
      atomicStore(gInterrupted, res, moRelease)
      break
  setEvent(addr readDone)

proc main() {.passive.} =
  var sv = default(array[2, cint])
  assert sockPair(addr sv[0]) == 0
  assert makeNonblocking(sv[0]) and makeNonblocking(sv[1])

  # A read parks until the peer writes, 20 ms later.
  spawnTask lateWriter(sv[1])
  var got = 0'u8
  let t0 = monoNow()
  assert waitRead(sv[0], addr got, 1, 1000) == 1
  let waited = int64(monoNow()) - int64(t0)
  assert got == 7
  assert waited >= 15_000_000 and waited < 1_000_000_000
  echo "PASS read parks until the peer writes"

  # A read on an empty socket gives up at its deadline.
  let t1 = monoNow()
  assert waitRead(sv[0], addr got, 1, 100) < 0
  let elapsed = int64(monoNow()) - int64(t1)
  assert elapsed >= 80_000_000 and elapsed < 2_000_000_000
  echo "PASS read deadline"

  # A sleep lasts at least its duration.
  let t2 = monoNow()
  sleepMs(30)
  assert int64(monoNow()) - int64(t2) >= 25_000_000
  echo "PASS sleep"

  # Two spawned tasks interleave at a yield.
  spawnTask yielder(1)
  spawnTask yielder(2)
  assert wait(addr yieldsDone, afterMs(2000)) == wrReady
  assert orderLen == 4
  var positions = default(array[13, int])
  for i in 0..<orderLen: positions[order[i]] = i
  assert positions[1] < positions[11] and positions[2] < positions[12]
  echo "PASS yield order"

  # interruptFd: a read parked on a pipe (a socket pair on Windows, where
  # only sockets can be polled) on another loop ends with ECancelled.
  var p: cint = -1
  var pw: cint = -1
  when defined(windows):
    var pv = default(array[2, cint])
    assert sockPair(addr pv[0]) == 0
    p = pv[0]
    pw = pv[1]
  else:
    assert wakePair(p, pw)
  spawnTask parkedRead(p)
  var spun = 0
  while atomicLoad(gInterrupted, moAcquire) != 1 and spun < 1000:
    sleepMs(1)
    spun = spun + 1
  sleepMs(20)
  if interruptFd(p):
    let t3 = monoNow()
    spun = 0
    while not isSet(addr readDone) and spun < 2000:
      sleepMs(1)
      spun = spun + 1
    assert atomicLoad(gInterrupted, moAcquire) == ECancelled
    echo "PASS interruptFd ended a parked pipe read (", (int64(monoNow()) - int64(t3)) div 1000, " us)"
  else:
    echo "SKIP interruptFd: not on the std backend"
    wakeSignal(pw)                          # let the reader finish
  assert wait(addr readDone, afterMs(2000)) == wrReady,
    "drain the reader before closing its descriptor"
  closeFd(p)
  if pw != p: closeFd(pw)
  closeFd(sv[0])
  closeFd(sv[1])

assert runMain(main())
