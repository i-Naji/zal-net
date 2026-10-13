import std/[assertions, atomics, syncio]
import zal_net/rt
import zal_net/rt/sync

var observed, steps, dropped: int
var done: Event

type OwnerState = object
  live: bool
type Owner = ref object
  state: OwnerState

proc `=destroy`(state: var OwnerState) =
  if state.live:
    state.live = false
    discard atomicFetchAdd(dropped, 1, moRelease)

proc observer() {.passive.} =
  atomicStore(observed, 1, moRelease)

proc step(owner: Owner) {.passive.} =
  assert owner.state.live
  assert atomicLoad(dropped, moAcquire) == 0
  discard atomicFetchAdd(steps, 1, moRelaxed)

proc chain(owner: Owner) {.passive.} =
  yieldNow()
  assert trySpawnTask(observer())
  for i in 0..<10000:
    step(owner)
  assert atomicLoad(observed, moAcquire) == 1
  parkUntil(afterMs(10))
  assert owner.state.live
  setEvent(addr done)

proc main() {.passive.} =
  block:
    let owner = Owner(state: OwnerState(live: true))
    assert trySpawnTask(chain(owner))
  assert wait(addr done, afterMs(5000)) == wrReady

assert runMain(main())
assert atomicLoad(steps, moAcquire) == 10000
assert atomicLoad(dropped, moAcquire) == 1
echo "PASS bounded continuation fairness and captured-owner cleanup"
