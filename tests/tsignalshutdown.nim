## Closing a signal watcher retains its descriptor while a passive wait borrows
## it, restores previous actions, and rejects late handlers after descriptor reuse.
import std/[assertions, syncio]
include zal_net/rt/signals

var entered: int
var finished: int
proc waiting() {.passive.} =
  atomicStore(entered, 1, moRelease)
  assert waitSignal() == sigNone
  atomicStore(finished, 1, moRelease)

when not defined(windows):
  proc kill(pid, sig: cint): cint {.importc, header: "<signal.h>".}
  proc getpid(): cint {.importc, header: "<unistd.h>".}
  when defined(macosx):
    proc errnoAddress(): ptr cint {.importc: "__error", header: "<errno.h>".}
  elif defined(linux):
    proc errnoAddress(): ptr cint {.importc: "__errno_location", header: "<errno.h>".}
  var oldCalls: int
  proc original(sig: cint) {.noconv.} =
    discard atomicFetchAdd(oldCalls, 1, moRelaxed)
  var originalAction = default(SigAct)
  var testAction = default(SigAct)
  testAction.sa_handler = original
  assert sigaction(number(sigUsr1), addr testAction, addr originalAction) == 0

proc main() {.passive.} =
  when defined(windows):
    assert watchSignals({sigInt})
    assert watchSignals({sigInt})
  else:
    assert watchSignals({sigUsr1})
    assert watchSignals({sigUsr1}) # must not replace the saved original action
  assert not joinSignals()
  when defined(macosx) or defined(linux):
    # Fill the nonblocking pipe so publication gets EAGAIN. A signal handler
    # must leave the interrupted code's errno unchanged even when it drops data.
    var byteValue = byte(number(sigUsr1))
    while sockWrite(gWr, addr byteValue, 1) == 1: discard
    let error = errnoAddress()
    error[] = 123
    onSignal(number(sigUsr1))
    assert error[] == 123
    wakeDrain(gRd)
  spawnTask waiting()
  while atomicLoad(entered, moAcquire) == 0 or atomicLoad(gUsers, moSequentiallyConsistent) == 0:
    parkUntil(afterMs(1))
  # Deterministically hold a handler's retained reference across stop. The std
  # worker may finish the actual wait before this caller reaches joinSignals.
  discard atomicFetchAdd(gUsers, 1, moSequentiallyConsistent)
  stopSignals()
  stopSignals()
  assert not joinSignals()
  assert not watchSignals({sigInt})
  discard atomicFetchSub(gUsers, 1, moSequentiallyConsistent)
  while atomicLoad(finished, moAcquire) == 0: parkUntil(afterMs(1))
  assert joinSignals()
  assert joinSignals()
  assert gRd == -1 and gWr == -1
  assert waitSignal(1) == sigNone
  when defined(windows):
    assert onConsole(number(sigInt)) == 0
  else:
    assert kill(getpid(), number(sigUsr1)) == 0
    let deadline = afterMs(1000)
    while atomicLoad(oldCalls, moRelaxed) == 0:
      assert monoNow() < deadline
      parkUntil(afterMs(1))
    assert atomicLoad(oldCalls, moRelaxed) == 1
    var rd: cint = -1
    var wr: cint = -1
    assert wakePair(rd, wr)
    onSignal(number(sigUsr1)) # a previously dispatched handler may arrive late
    var value = 0'u8
    assert sockRead(rd, addr value, 1) < 0
    wakeClose(rd, wr)
    assert sigaction(number(sigUsr1), addr originalAction, nil) == 0
  echo "PASS signal wait drain, action restoration, repeated close and late handler"
  requestStop()

initRuntime()
spawnTask main()
drainRuntime()
