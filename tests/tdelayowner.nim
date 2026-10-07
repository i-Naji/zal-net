import std/[assertions, atomics, syncio]
import zal_net/rt
import zal_net/rt/sync

type
  Probe = object
    live: bool
  Owner = ref object
    probe: Probe
var dropped: int
var done: Event
proc `=destroy`(probe: var Probe) =
  if probe.live:
    probe.live = false
    discard atomicFetchAdd(dropped, 1, moRelease)
proc child(owner: Owner) {.passive.} =
  parkUntil(afterMs(20))
  assert atomicLoad(dropped, moAcquire) == 0
  assert owner.probe.live
  setEvent(addr done)
proc main() {.passive.} =
  block:
    let owner = Owner(probe: Probe(live: true))
    assert trySpawnTask(child(owner))
  assert atomicLoad(dropped, moAcquire) == 0
  assert wait(addr done, afterMs(2000)) == wrReady
assert runMain(main())
assert atomicLoad(dropped, moAcquire) == 1
echo "PASS delayed borrowed argument retained through completion"
