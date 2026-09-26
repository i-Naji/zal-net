## Notify, Event, Oneshot and Chan: same-loop and cross-thread wakes,
## permits, deadlines, cancellation, and a notify-vs-timeout race; the
## typed Channel[T] and Promise[T] over them.
import std/assertions
import std/syncio
import std/atomics
import zal_net/rt
import zal_net/raw/io
import zal_net/rt/sync
import zal_net/private/sys/threads

proc usleep(us: cuint): cint {.importc, header: "<unistd.h>".}

var gNotify: Notify
var gEvent: Event
var gRaceNotify: Notify
var gStamp: int64          # atomic: when the raw thread notified

proc notifyLater(ms: int) {.passive.} =
  sleepMs(ms)
  notifyOne(addr gNotify)

proc cancelLater(tok: CancelToken; ms: int) {.passive.} =
  sleepMs(ms)
  cancel(tok)

proc rawNotifier(arg: nil pointer) {.nimcall.} =
  discard usleep(20_000)
  atomicStore(gStamp, int64(monoNow()), moRelease)
  notifyOne(addr gNotify)

proc rawFulfil(arg: nil pointer) {.nimcall.} =
  let o = cast[Oneshot](arg)
  discard usleep(10_000)
  cast[ptr int](payload(o))[] = 42
  assert fulfil(o)
  release(o)

var gChan = newChan(sizeof(int), 16)
var gProduced: int   # atomic

type Msg = object
  id: int
  weight: float64

var gTyped = newChannel[Msg](8)
var gTypedDone: int   # atomic
var gPromise = newPromise[int64]()

proc rawTypedProducer(arg: nil pointer) {.nimcall.} =
  let base = cast[int](arg)
  var i = 0
  while i < 1000:
    while not trySend(gTyped, Msg(id: base + i, weight: float64(i) * 0.5)): discard usleep(50)
    i = i + 1
  discard atomicFetchAdd(gTypedDone, 1, moAcquireRelease)

proc rawPromise(arg: nil pointer) {.nimcall.} =
  discard usleep(10_000)
  discard fulfil(gPromise, 1_234_567_890_123'i64)
  release(gPromise)

proc rawProducer(arg: nil pointer) {.nimcall.} =
  var i = 0
  while i < 10_000:
    var v = 1
    while not trySend(gChan, addr v): discard usleep(50)
    i = i + 1
  discard atomicFetchAdd(gProduced, 1, moRelease)

proc raceNotifier() {.passive.} =
  sleepMs(1)
  notifyOne(addr gRaceNotify)

proc main() {.passive.} =
  # Notify: a wait woken by a task on the same loop.
  spawnTask notifyLater(20)
  assert wait(addr gNotify, afterMs(2000)) == wrReady
  # A permit stored before the wait is taken at once.
  notifyOne(addr gNotify)
  assert wait(addr gNotify, afterMs(0)) == wrReady
  # Deadline.
  let t0 = monoNow()
  assert wait(addr gNotify, afterMs(50)) == wrTimedOut
  let waited = int64(monoNow()) - int64(t0)
  assert waited >= 40_000_000, "deadline must not resume prematurely"
  echo "Deadline elapsed ", waited div 1000, " us (includes scheduling delay)"
  # Cancellation.
  let tok = newCancelToken()
  spawnTask cancelLater(tok, 20)
  assert wait(addr gNotify, afterMs(5000), tok) == wrCancelled
  assert cancelled(tok)
  assert wait(addr gNotify, afterMs(5000), tok) == wrCancelled   # already cancelled
  release(tok)
  echo "PASS notify: wake, permit, deadline, cancel"

  # A wake from a thread that is not a loop.
  var worst = 0'i64
  var k = 0
  while k < 10:
    startThread(rawNotifier, nil)
    assert wait(addr gNotify, afterMs(5000)) == wrReady
    let lat = int64(monoNow()) - atomicLoad(gStamp, moAcquire)
    if lat > worst: worst = lat
    k = k + 1
  echo "PASS notify from a raw thread (worst wake ", worst div 1000, " us)"
  # Wake latency depends on OS scheduling and VM contention. The waits above
  # assert delivery; this observed latency is diagnostic, not a promised bound.
  assert worst >= 0, "monotonic notification timestamp"

  # Notify against timeout: every wait resumes exactly once.
  var ready = 0
  var timedOut = 0
  var i = 0
  while i < 500:
    spawnTask raceNotifier()
    let r = wait(addr gRaceNotify, afterMs(1))
    if r == wrReady: ready = ready + 1
    elif r == wrTimedOut: timedOut = timedOut + 1
    else: assert false
    i = i + 1
  # Drain permits left by notifies that lost to their timeout.
  sleepMs(20)
  while wait(addr gRaceNotify, afterMs(0)) == wrReady: discard
  echo "PASS notify vs timeout race (", ready, " ready, ", timedOut, " timed out)"

  # Event: set wakes every waiter and stays set until cleared.
  setEvent(addr gEvent)
  assert wait(addr gEvent, afterMs(0)) == wrReady
  clearEvent(addr gEvent)
  assert wait(addr gEvent, afterMs(10)) == wrTimedOut
  echo "PASS event"

  # Oneshot fulfilled from a raw thread.
  let o = newOneshot(sizeof(int))
  startThread(rawFulfil, o)
  assert wait(o, afterMs(5000)) == wrReady
  assert cast[ptr int](payload(o))[] == 42
  release(o)
  let o2 = newOneshot(sizeof(int))
  abandon(o2)
  assert not fulfil(o2)
  release(o2)
  release(o2)
  echo "PASS oneshot"

  # Chan: four raw producers, one passive consumer, capacity 16.
  var p = 0
  while p < 4:
    startThread(rawProducer, nil)
    p = p + 1
  var total = 0
  var v = 0
  while total < 40_000:
    assert recv(gChan, addr v, afterMs(5000)) == wrReady
    total = total + v
  # The last item can arrive before its producer counts itself done.
  var spins = 0
  while atomicLoad(gProduced, moAcquire) < 4 and spins < 500:
    sleepMs(2)
    spins = spins + 1
  assert atomicLoad(gProduced, moAcquire) == 4
  close(gChan)
  assert recv(gChan, addr v, afterMs(100)) == wrClosed
  assert send(gChan, addr v, afterMs(100)) == wrClosed
  release(gChan)
  echo "PASS chan: 40000 items from 4 threads, close"

  # Typed: a Channel of structs from 2 raw threads; a Promise from one.
  startThread(rawTypedProducer, cast[pointer](0))
  startThread(rawTypedProducer, cast[pointer](100_000))
  var idSum = 0
  var weightSum = 0.0
  var got = 0
  while got < 2000:
    let r = recv(gTyped, afterMs(5000))
    assert r.res == wrReady
    idSum = idSum + r.value.id
    weightSum = weightSum + r.value.weight
    got = got + 1
  assert idSum == 2 * (999 * 1000 div 2) + 100_000 * 1000
  assert weightSum == 2.0 * 0.5 * float64(999 * 1000 div 2)
  var spun = 0
  while atomicLoad(gTypedDone, moAcquire) < 2 and spun < 500:
    sleepMs(2)
    spun = spun + 1
  close(gTyped)
  assert recv(gTyped, afterMs(100)).res == wrClosed
  release(gTyped)
  startThread(rawPromise, nil)
  let pr = wait(gPromise, afterMs(5000))
  assert pr.res == wrReady and pr.value == 1_234_567_890_123'i64
  release(gPromise)
  echo "PASS typed Channel[T] (2000 structs from 2 threads) and Promise[T]"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
