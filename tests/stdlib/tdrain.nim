## Close admission interrupts bounded readiness waits without std cancellation.
import std/[ioring, threadpool, atomics, assertions, syncio]
import zal_net/foundation/admission
when not defined(posix):
  {.error: "This socketpair probe currently requires POSIX".}
proc socketpair(domain, kind, protocol: cint; fds: ptr cint): cint {.importc.}
proc nativeClose(fd: cint): cint {.importc: "close".}

var entered, completed, closes: int
proc borrow(gate: sink ResourceGate; fd: cint; lease: sink OperationLease) {.passive.} =
  discard atomicFetchAdd(entered, 1, moRelease)
  while phase(gate) == resourceOpen:
    var outcome = 0
    let continuation = delay()
    discard submitPollAdd(fd, afterMs(10), {evRead}, continuation, addr outcome)
    suspend()
    assert outcome == IoTimedOut
  release(lease)
  assert claimCleanup(gate)
  assert nativeClose(fd) == 0
  discard atomicFetchAdd(closes, 1, moRelease)
  finishCleanup(gate)
  discard atomicFetchAdd(completed, 1, moRelease)

const Count = 96
for round in 0..<10:
  var gates: seq[ResourceGate] = @[]
  var peers: seq[cint] = @[]
  for i in 0..<Count:
    var pair = default(array[2, cint])
    assert socketpair(1, 1, 0, addr pair[0]) == 0
    setNonBlocking(pair[0])
    let gate = newResourceGate()
    gates.add gate
    peers.add pair[1]
    var outcome = admissionClosed
    let lease = admit(gate, operationRead, outcome)
    assert lease != nil
    submit(delay(borrow(gate, pair[0], lease)))
  let deadline = afterMs(5000)
  while atomicLoad(entered, moAcquire) < (round + 1) * Count:
    assert monoNow() < deadline
  for gate in gates:
    assert beginClosing(gate)
    assert not beginClosing(gate)
    var outcome = admissionAccepted
    assert admit(gate, operationRead, outcome) == nil and outcome == admissionClosed
  while atomicLoad(completed, moAcquire) < (round + 1) * Count:
    assert monoNow() < deadline
  for gate in gates:
    assert phase(gate) == resourceClosed
    assert not claimCleanup(gate)
  for fd in peers: assert nativeClose(fd) == 0
assert atomicLoad(closes, moAcquire) == Count * 10
shutdown()
echo "PASS unchanged std: 960 close/drain cycles, 96 concurrent owners"
