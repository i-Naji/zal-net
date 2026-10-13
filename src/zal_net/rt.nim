## Task admission, readiness waits and process-owned standard-runtime shutdown.

import std/atomics
from std/rawthreads import getThreadId
import zal_net/rt/time
import zal_net/private/sys/posix
import zal_net/private/sys/env
import zal_net/private/sys/oom
export time, env, oom

import zal_net/private/runtime
# Explicit low-level operations; scheduling internals stay private.
export closeFd, closeFdRaw, runtimeWorkers

var gRuntimeUp: int
var gRunEntered: int
let gRuntimeThread = getThreadId() # immutable identity of module initialization

proc initRuntime*() =
  ## Initialize process services. ZAL_WORKERS is read before the standard ring starts.
  if atomicLoad(gRuntimeUp, moAcquire) == 2: return
  var expected = 0
  if not atomicCompareExchange(gRuntimeUp, expected, 1, moAcquireRelease, moAcquire):
    while atomicLoad(gRuntimeUp, moAcquire) != 2: cpuRelax()
    return
  installOomHandler()
  ignoreSigpipe()
  discard raiseFdLimit()
  beInit()
  atomicStore(gRuntimeUp, 2, moRelease)

proc drainRuntime*() =
  ## Drain the process runtime on its entry thread after requestStop.
  if getThreadId() != gRuntimeThread: return
  var expected = 0
  if not atomicCompareExchange(gRunEntered, expected, 1, moAcquireRelease, moAcquire): return
  beRun()

proc requestStop*() =
  ## Stop admission, drain owned tasks and join the process pool. No restart.
  beStop()

proc runtimeFinished*(): bool =
  ## True after admitted tasks, workers and runtime pollers have finished.
  beFinished()

proc stopping*(): bool {.inline.} =
  ## True once a stop was requested; long-running tasks can check it.
  beStopping()

template trySpawnTask*(call: untyped): bool =
  ## Queue a passive call, or return false before allocating its frame when
  ## shutdown has begun. A rejected call leaves its resources with the caller.
  beTrySpawn(call)

template trySpawnCleanupTask*(call: untyped): bool =
  ## Library cleanup for an already-owned resource. It may join the drain after
  ## normal task admission closes; it cannot restart a finished runtime.
  beTryCleanup(call)
template spawnTask*(call: untyped) =
  ## Queue a passive call on the standard pool.
  beSpawn(call)

proc enterMain(): bool =
  if getThreadId() != gRuntimeThread or onLoop() or beStopping(): return false
  var expected = 0
  result = atomicCompareExchange(gRunEntered, expected, 1, moAcquireRelease, moAcquire)

proc finishMain(frame: ptr CoroutineBase): Continuation {.nimcall.} =
  ## frame is the calling thread's completion anchor, borrowed until beRun
  ## returns. It is never dereferenced or freed by the continuation.
  requestStop()
  result = default(Continuation)

template runMain*(call: untyped): bool =
  ## One process-owned runtime entry from regular code. The void passive root
  ## requests shutdown on return; it must drain its owned children first.
  ## Nested/second entries return false without evaluating `call`.
  ## The standard pool is joined only here, by the process-owned runner.
  block:
    var accepted = enterMain()
    if accepted:
      var completion = default(CoroutineBase)
      initRuntime()
      accepted = beTryRoot(call, Continuation(fn: finishMain, env: addr completion))
      if accepted: beRun()
      else: requestStop()
    accepted

template startInline*(call: untyped) =
  ## Run a new passive call on the caller's trampoline until it first
  ## suspends.
  beStartInline(delay(call))

template tryStartConn*(call: untyped): bool =
  ## False after shutdown begins, before a passive frame is allocated. The caller
  ## keeps ownership of resources that the new handler would have taken.
  beTryStartConn(call)

template startConn*(call: untyped) =
  ## Start a connection handler where the backend places connections.
  beStartConn(call)

proc transientIo*(n: int): bool {.inline.} =
  n == -EIntr or n == -EAgain

proc touchIo*(activity: nil ptr int64) =
  if activity == nil: return
  let a: ptr int64 = activity
  # Timeouts are in milliseconds. Round up so expiry is never early,
  # and publish at most once per millisecond instead of bouncing a shared
  # cache line between two pumps on every successful read/write.
  let now = (int64(monoNow()) div 1_000_000 + 1) * 1_000_000
  var previous = atomicLoad(a[], moRelaxed)
  while previous < now:
    if atomicCompareExchange(a[], previous, now, moRelaxed, moRelaxed): break

proc ioDeadline*(activity: nil ptr int64; timeoutMs: int): Deadline =
  if activity == nil: return afterMs(timeoutMs)
  result = Deadline(atomicLoad(activity[], moRelaxed) + int64(timeoutMs) * 1_000_000)

proc interruptFd*(fd: cint): bool =
  ## Descriptor-wide cancellation is unavailable; use owner/token cancellation.
  result = beInterruptFd(fd)

proc nudgeFd*(fd: cint): bool =
  ## Descriptor-wide wakeups are unavailable on the standard runtime.
  result = beNudgeFd(fd)

template parkPoll*(fd: cint; events: IoEvents; deadline: Deadline; res: var int) =
  ## Suspend until `fd` is ready for `events` (one direction), against a
  ## fixed deadline that progress does not extend. `res` > 0 on readiness,
  ## IoTimedOut, ECancelled (closed while parked) or -1.
  beParkFd(fd, evWrite in events, false, deadline, res)

template parkPollOwned*(fd: cint; events: IoEvents; deadline: Deadline; res: var int) =
  ## `parkPoll` for a socket whose owner close and runtime stop interrupt it:
  ## one poll on the real deadline.
  beParkFd(fd, evWrite in events, false, deadline, res, false)

template parkReady*(fd: cint; events: IoEvents; activity: nil ptr int64;
                    timeoutMs: int; res: var int) =
  ## Like `parkPoll`, but the idle deadline follows the shared activity
  ## stamp, so traffic in the other direction keeps a quiet direction alive.
  block:
    var deadline = ioDeadline(activity, timeoutMs)
    while true:
      beParkFd(fd, evWrite in events, false, deadline, res)
      if res > 0: break
      if res == IoTimedOut and activity != nil:
        deadline = ioDeadline(activity, timeoutMs)
        if monoNow() < deadline: continue
        break
      if not transientIo(res): break

template parkAccept*(listenFd: cint; res: var int) =
  ## Suspend until a shared listener has a pending connection.
  beParkFd(listenFd, false, true, never, res)

template parkUntil*(deadline: Deadline) =
  beParkUntil(deadline)

template yieldNow*() =
  ## Let this loop's other continuations and its I/O run first.
  beYield()

const
  ReadyIoBytes = 1024 * 1024
  ReadyIoCalls = 256
var readyIoBytes {.threadvar.}: int
var readyIoCalls {.threadvar.}: int

proc exhaustedIoBudget(work: int): bool {.inline.} =
  # Thread-local: custom-loop tasks share a budget; std workers never race on it.
  readyIoBytes += min(max(work, 0), ReadyIoBytes)
  inc readyIoCalls
  result = readyIoBytes >= ReadyIoBytes or readyIoCalls >= ReadyIoCalls
  if result:
    readyIoBytes = 0
    readyIoCalls = 0

template ioCheckpoint*(work: int) =
  ## Bound runs of immediately ready operations. Keep operation/owner admission
  ## held across this checkpoint, and recheck cancellation/state after it.
  ## Protocols with buffered data should charge their own bounded work too.
  if exhaustedIoBudget(work): yieldNow()
