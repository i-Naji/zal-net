## Public-API contract probe against the unmodified pinned standard runtime.
## No completion read/write borrows caller memory. Socket I/O is nonblocking.
import std/[ioring, threadpool, atomics, assertions, syncio]

when not defined(posix):
  {.error: "This socketpair probe currently requires POSIX".}

proc socketpair(domain, kind, protocol: cint; fds: ptr cint): cint {.importc.}
proc nativeRead(fd: cint; data: pointer; count: int): int {.importc: "read".}
proc nativeWrite(fd: cint; data: pointer; count: int): int {.importc: "write".}
proc nativeClose(fd: cint): cint {.importc: "close".}

var finished, timedOut, ready, liveCaptures, destroyedCaptures: int

type OwnerData = object
  marker: int
proc `=destroy`(owner: var OwnerData) =
  assert owner.marker == 73
  discard atomicFetchAdd(destroyedCaptures, 1, moRelease)
type Owner = ref OwnerData

template waitReadable(fd: cint; deadline: Deadline; answer: var int) =
  block:
    let continuation = delay()
    discard submitPollAdd(fd, deadline, {evRead}, continuation, addr answer)
    suspend()

template pause(milliseconds: int) =
  block:
    let continuation = delay()
    discard submitTimeout(afterMs(milliseconds), continuation)
    suspend()

proc receive(fd: cint; owner: sink Owner) {.passive.} =
  assert isPoolWorker()
  assert owner.marker == 73
  discard atomicFetchAdd(liveCaptures, 1, moAcquireRelease)
  var response = 99
  waitReadable(fd, afterMs(2), response)
  assert response == IoTimedOut
  discard atomicFetchAdd(timedOut, 1, moRelease)
  # Timeout leaves the stream usable; a subsequent wait gets real data.
  waitReadable(fd, afterMs(3000), response)
  assert response >= 0
  var value = '\0'
  assert nativeRead(fd, addr value, 1) == 1
  assert value == 'x' and owner.marker == 73
  discard atomicFetchAdd(ready, 1, moRelease)
  # Both waits have resumed before this descriptor can be reused.
  assert nativeClose(fd) == 0
  discard atomicFetchSub(liveCaptures, 1, moRelease)
  discard atomicFetchAdd(finished, 1, moRelease)

proc send(fd: cint; round: int) {.passive.} =
  assert isPoolWorker()
  while atomicLoad(timedOut, moAcquire) <= round:
    pause(1)
  var value = 'x'
  assert nativeWrite(fd, addr value, 1) == 1
  assert nativeClose(fd) == 0
  discard atomicFetchAdd(finished, 1, moRelease)

const Rounds = 200
for round in 0..<Rounds:
  var pair = default(array[2, cint])
  assert socketpair(1, 1, 0, addr pair[0]) == 0
  setNonBlocking(pair[0])
  setNonBlocking(pair[1])
  block:
    let owner = Owner(marker: 73)
    submit(delay(receive(pair[0], owner)))
    submit(delay(send(pair[1], round)))
  let deadline = afterMs(5000)
  while atomicLoad(finished, moAcquire) < (round + 1) * 2:
    assert monoNow() < deadline, "standard readiness continuation was lost"
assert atomicLoad(ready, moAcquire) == Rounds
assert atomicLoad(liveCaptures, moAcquire) == 0
shutdown()
assert atomicLoad(destroyedCaptures, moAcquire) == Rounds
echo "PASS unchanged std: ", Rounds, " timeout/reuse/capture cycles; workers=", workerCount
