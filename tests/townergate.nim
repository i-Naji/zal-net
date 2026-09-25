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

proc main() {.passive.} =
  initOwnerLife(life)
  assert beginBorrow(life, false) == 0
  assert beginClose(life) == 0
  endBorrow(life, false)
  signalIdle(life)
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
