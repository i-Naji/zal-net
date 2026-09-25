## Compiler guard: a passive task must retain its managed owner across a park.
## This is a prerequisite probe, not an implementation of the friendly API.
import std/[assertions, syncio]
import zal_net/rt, zal_net/rt/sync

var destroyed = 0
type Owner = object
  value: int
type OwnerRef = ref Owner

proc `=destroy`(owner: var Owner) =
  if owner.value == 0: return
  assert owner.value == 73
  destroyed = destroyed + 1

var entered = default(Event)
var resume = default(Event)
var finished = default(Event)

proc borrow(owner: sink OwnerRef) {.passive.} =
  let held = owner
  setEvent(addr entered)
  assert wait(addr resume, afterMs(2000)) == wrReady
  assert held.value == 73
  setEvent(addr finished)

proc main() {.passive.} =
  var owner: nil OwnerRef = nil
  block:
    let created = OwnerRef()
    created.value = 73
    owner = created
    assert trySpawnTask(borrow(created))
  owner = nil
  assert destroyed == 0, "destroyed before queued borrower started: " & $destroyed
  assert wait(addr entered, afterMs(2000)) == wrReady
  assert destroyed == 0, "destroyed before passive borrower finished: " & $destroyed
  setEvent(addr resume)
  assert wait(addr finished, afterMs(2000)) == wrReady
  yieldNow()
  assert destroyed == 1, "last passive reference cleanup count: " & $destroyed
  echo "PASS managed owner retained by suspended passive task"

assert runMain(main())
