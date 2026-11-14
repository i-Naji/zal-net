{.feature: "assumeSync".}
## Borrower acknowledgement is not final cleanup. Close deadlines must still
## expire when the idle event is ready but retained cleanup has not finished.
import std/[assertions, syncio]
import zal_net/[rt, errors], zal_net/rt/sync
import zal_net/ownership

var life = default(OwnerLife)
var finished = default(Event)
var allowCleanup = default(Event)
var watchdogDone = default(Event)
var observedTimeout = false
var forcedCleanup = false

proc finishClose() {.passive.} =
  discard wait(addr allowCleanup, never)
  markClosed(life)
  setEvent(addr finished)

proc watchdog() {.passive.} =
  # Logical loop progress, not a wall-clock latency assertion. Bound a broken
  # old helper without leaving the expected-failure executable spinning forever.
  var turns = 0
  while not observedTimeout and turns < 256:
    yieldNow()
    turns = turns + 1
  if not observedTimeout:
    forcedCleanup = true
    setEvent(addr allowCleanup)
  setEvent(addr watchdogDone)

proc waitForBorrowers(gate: ptr OwnerLife; entered, done: ptr Event) {.passive.} =
  setEvent(entered)
  drainBorrowers(gate)
  setEvent(done)

proc checkAcknowledgement(controlLast: bool) {.passive.} =
  var gate = default(OwnerLife)
  var entered, done = default(Event)
  initOwnerLife(gate)
  assert beginBorrow(gate, false) == 0
  assert beginControl(gate) == 0
  assert beginClose(gate) == 0
  assert trySpawnTask(waitForBorrowers(addr gate, addr entered, addr done))
  assert wait(addr entered, afterMs(2000)) == wrReady
  for turn in 0..<32: yieldNow()
  if controlLast: endBorrow(gate, false)
  else: endControl(gate)
  assert not isIdle(gate) and not isSet(addr done)
  if controlLast: endControl(gate)
  else: endBorrow(gate, false)
  let outcome = wait(addr done, afterMs(2000))
  if outcome != wrReady:
    markClosed(gate)
    discard wait(addr done, afterMs(2000))
  assert outcome == wrReady, "last operation wakes a parked close without a separate signal"
  assert claimOwnerCleanup(gate)
  markClosed(gate)

proc main() {.passive.} =
  checkAcknowledgement(false)
  checkAcknowledgement(true)
  initOwnerLife(life)
  assert beginBorrow(life, false) == 0
  assert beginClose(life) == 0
  endBorrow(life, false)
  assert beginClose(life) == 0, "repeated close preserves acknowledgement"
  assert trySpawnTask(finishClose())
  # Cleanup is blocked independently until timeout is observed. The watchdog
  # eventually releases a broken old helper after bounded logical loop turns.
  let outcome = drainClose(addr life, afterMs(0))
  observedTimeout = outcome == IoTimedOut
  assert outcome == IoTimedOut, "idle acknowledgement must not waive close deadline"
  assert state(life) == ownerClosing, "timed-out waiter must not release cleanup state"
  setEvent(addr allowCleanup)
  assert drainClose(addr life, never) == 0
  assert state(life) == ownerClosed
  assert wait(addr finished, never) == wrReady
  assert not forcedCleanup, "close deadline must complete before logical watchdog"
  assert drainClose(addr life, afterMs(-1)) == 0, "completed close wins expired deadline"
  assert beginBorrow(life, false) == ResourceClosed
  echo "PASS close deadline, independent completion and retained eventual cleanup"

assert runMain(main())
