## Two reads may share readiness; only a completed syscall resumes its reader.
import poolsetup
import std/[threadpool, ioring, atomics, assertions, syncio]

when not defined(posix):
  {.error: "This socketpair probe requires POSIX".}
proc socketpair(domain, kind, protocol: cint; fds: ptr cint): cint {.importc.}
{.compile: "nonblock.c".}
proc makeNonblocking(fd: cint): cint {.importc: "zal_test_nonblock".}
proc nativeWrite(fd: cint; data: pointer; count: int): int {.importc: "write".}
proc nativeClose(fd: cint): cint {.importc: "close".}
var submitted, finished, received: int

template pause(milliseconds: int) =
  block:
    let continuation = delay()
    discard submitTimeout(afterMs(milliseconds), continuation)
    suspend()

proc reader(fd: cint) {.passive.} =
  var byteValue = '\0'
  var count = -1
  discard atomicFetchAdd(submitted, 1, moRelease)
  let continuation = delay()
  discard submitRead(fd, addr byteValue, 1, never, continuation, addr count)
  suspend()
  assert count == 1, "readiness must not complete a read with EAGAIN"
  assert byteValue == 'x' or byteValue == 'y'
  discard atomicFetchOr(received, if byteValue == 'x': 1 else: 2, moAcquireRelease)
  discard atomicFetchAdd(finished, 1, moRelease)

proc writer(fd: cint; expected: int) {.passive.} =
  while atomicLoad(submitted, moAcquire) < expected: pause(1)
  pause(10)
  var value = 'x'
  assert nativeWrite(fd, addr value, 1) == 1
  pause(20)
  value = 'y'
  assert nativeWrite(fd, addr value, 1) == 1
  discard atomicFetchAdd(finished, 1, moRelease)

when defined(linux) and not defined(nimIoringNoUring):
  shutdown()
  echo "SKIP shared-readiness probe: io_uring reports EAGAIN directly"
  quit 0
assert workerCount == 4
for round in 0..<100:
  var pair = default(array[2, cint])
  assert socketpair(1, 1, 0, addr pair[0]) == 0
  assert makeNonblocking(pair[0]) == 0
  assert makeNonblocking(pair[1]) == 0
  atomicStore(received, 0, moRelease)
  submit(delay(reader(pair[0])))
  submit(delay(reader(pair[0])))
  submit(delay(writer(pair[1], (round + 1) * 2)))
  let deadline = afterMs(5000)
  var completions = default(array[16, IoCompletion])
  while atomicLoad(finished, moAcquire) < (round + 1) * 3:
    discard pollCompletions(completions)
    if monoNow() >= deadline:
      echo "round=", round, " submitted=", atomicLoad(submitted, moAcquire), " finished=", atomicLoad(finished, moAcquire), " received=", atomicLoad(received, moAcquire)
      assert false, "second reader was not resumed"
  assert atomicLoad(received, moAcquire) == 3
  assert nativeClose(pair[0]) == 0 and nativeClose(pair[1]) == 0
shutdown()
echo "PASS 100 shared-readiness pairs; workers=", workerCount
