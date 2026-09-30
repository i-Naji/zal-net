## Registration capacity rejects before consuming a native descriptor.
import std/[assertions, syncio]
import std/atomics
import zal_net/rt
import zal_net/raw/io
import zal_net/private/sys/sock
import zal_net/foundation/readiness

var released, completed: int
proc child() {.passive.} =
  while atomicLoad(released, moAcquire) == 0: yieldNow()
  discard atomicFetchAdd(completed, 1, moRelease)

proc main() {.passive.} =
  var admitted = 0
  while trySpawnTask(child()): inc admitted
  assert admitted > 0 and admitted <= 8192, "task admission must remain bounded"
  let ready = newReadiness()
  var pair = [-1.cint, -1.cint]
  assert sockPair(addr pair[0]) == 0, "socketpair creation"
  assert sockSetNonblock(pair[0], true), "nonblocking socketpair"
  assert not watch(ready, pair[0], 17), "exhausted admission must reject registration"
  var data = 21'u8
  assert writeSome(pair[1], addr data, 1) == 1
  assert readSome(pair[0], addr data, 1) == 1 and data == 21
  assert retire(ready, pair[0]) == nil, "rejection must not install a registration"
  atomicStore(released, 1, moRelease)
  let deadline = afterMs(10000)
  while atomicLoad(completed, moAcquire) != admitted:
    assert monoNow() < deadline, "capacity children must finish"
    yieldNow()
  # Child bodies have returned; their tracked completion also retires admission.
  while not watch(ready, pair[0], 18):
    assert monoNow() < deadline, "capacity must recover after child completion"
    yieldNow()
  assert writeSome(pair[1], addr data, 1) == 1
  let event = nextReady(ready, afterMs(2000))
  assert event.registration != nil and event.tag == 18, "recovered registration reports readiness"
  let retired = retire(ready, pair[0])
  assert retired != nil
  if retired != nil: join(retired)
  discardReady(ready)
  closeFd(pair[0])
  closeFd(pair[1])
  requestStop()
  echo "PASS registration capacity rejection, descriptor preservation and recovery"

assert runMain(main())
