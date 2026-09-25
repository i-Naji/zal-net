import std/[assertions, syncio, atomics, threadpool, ioring]
import zal_net/foundation/admission

block aliasesAndClose:
  let gate = newResourceGate()
  var outcome = admissionClosed
  let writer = admit(gate, operationWrite, outcome)
  assert writer != nil and outcome == admissionAccepted
  let alias = writer
  assert admit(gate, operationWrite, outcome) == nil and outcome == admissionBusy
  let reader = admit(gate, operationRead, outcome)
  assert reader != nil
  let child = admit(gate, operationTask, outcome)
  assert child != nil
  assert beginClosing(gate) and not beginClosing(gate)
  assert admit(gate, operationTask, outcome) == nil and outcome == admissionClosed
  assert not claimCleanup(gate)
  release(writer)
  release(alias)
  release(reader)
  assert not claimCleanup(gate) # Cancellation is not child completion.
  release(child)
  assert claimCleanup(gate) and not claimCleanup(gate)
  finishCleanup(gate)
  assert phase(gate) == resourceClosed

block automaticRelease:
  let gate = newResourceGate()
  block:
    var outcome = admissionClosed
    let lease = admit(gate, operationWrite, outcome)
    assert lease != nil
  assert beginClosing(gate) and claimCleanup(gate)
  finishCleanup(gate)

var completed, inside, visits: int
proc contender(gate: sink ResourceGate) {.passive.} =
  var count = 0
  while count < 100:
    var outcome = admissionClosed
    let lease = admit(gate, operationWrite, outcome)
    if lease != nil:
      assert atomicFetchAdd(inside, 1, moAcquireRelease) == 0
      # A suspended logical write retains its exclusion on a different worker.
      let continuation = delay()
      discard submitTimeout(afterMs(1), continuation)
      suspend()
      assert atomicFetchSub(inside, 1, moAcquireRelease) == 1
      release(lease)
      discard atomicFetchAdd(visits, 1, moRelease)
      inc count
    else:
      assert outcome == admissionBusy
      let continuation = delay()
      discard submitTimeout(afterMs(1), continuation)
      suspend()
  discard atomicFetchAdd(completed, 1, moRelease)

let shared = newResourceGate()
for i in 0..<8: submit(delay(contender(shared)))
let deadline = afterMs(15000)
while atomicLoad(completed, moAcquire) != 8:
  assert monoNow() < deadline
assert atomicLoad(visits, moAcquire) == 800
assert beginClosing(shared) and claimCleanup(shared)
finishCleanup(shared)
shutdown()
echo "PASS shared leases, joined close and 800 writes across pool workers"
