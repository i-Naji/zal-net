## Standard-pool adapter. Nonblocking native I/O borrows caller buffers;
## only readiness and timers enter std/ioring. No std reactor state is changed.
when not defined(gcAtomicArc):
  {.error: "Standard runtime handles require --mm:atomicArc".}

import std/[syncio, assertions]
import std/atomics
import std/ticketlocks
import std/stripes
from std/rawthreads import getThreadId
from zal_net/private/sys/sock import sleepUs
from zal_net/private/sys/posix import fdLimits
from zal_net/private/sys/env import tasksFromEnv, MaxTasks
import std/threadpool
import std/ioring
import zal_net/rt/time
import zal_net/private/core/waitq
import zal_net/private/backend/efdpool
import zal_net/private/core/parked
import zal_net/private/services

proc closeFd*(fd: cint) =
  ## Final native release after borrowers drain. Cancellation is requested
  ## separately; this operation does not retire another lane's pending waits.
  ioring.closeFdRaw(fd)

proc closeFdRaw*(fd: cint) =
  ## Close a descriptor with no pending operations.
  ioring.closeFdRaw(fd)

const ExternalCapacity = 8192
# Admitted tasks; ZAL_TASKS, else the descriptor limit. Most tasks hold a socket.
var gTaskLimit = ExternalCapacity
var external: FifoStripe[Continuation]
external.init(ExternalCapacity)
let entryThread = getThreadId()

proc enqueueExternal(queue: var FifoStripe[Continuation]; c: Continuation): bool {.sync.} =
  # FifoStripe serializes its storage internally.
  {.cast(assumeSync).}:
    result = queue.tryEnqueue(c)

proc dequeueExternal(queue: var FifoStripe[Continuation]; incoming: var openArray[Continuation]): int {.sync.} =
  {.cast(assumeSync).}:
    result = queue.tryBulkDequeue(incoming.len, incoming)

proc prepareRoot(root: var CoroutineBase; completion: Continuation) {.sync.} =
  # The process entry winner initializes this before publishing its first task.
  {.cast(assumeSync).}:
    root.caller = completion

const ResumeSteps = 128
const SliceMs = 10
const SliceMaxMs = 200
# A wrapper may still have completion work after its child releases admission.
var gResuming: int
var resumeAnchor = default(CoroutineBase)

proc finishedResume(frame: ptr CoroutineBase): Continuation {.nimcall.} =
  discard atomicFetchSub(gResuming, 1, moAcquireRelease)
  result = default(Continuation)

proc resumeChain(c: Continuation) {.passive.} =
  # Preserve the child's completion caller. Bound immediate steps to return
  # control to the pool and limit stack growth in generated passive loops.
  var pending = c
  var steps = 0
  # Shared pools need frequent readiness turns under concurrent load.
  let budget = if workerCount == 1: ResumeSteps else: 2
  while pending.fn != nil:
    pending = advance(pending)
    inc steps
    if pending.fn != nil and steps == budget:
      let resume = delay()
      if isPoolWorker(): submit(resume)
      else: discard submitNop(never, resume)
      suspend()
      steps = 0

proc grouped(c: Continuation): Continuation =
  discard atomicFetchAdd(gResuming, 1, moAcquireRelease)
  result = delay(resumeChain(c))
  result.env[].caller = Continuation(fn: finishedResume, env: addr resumeAnchor)

proc schedule(c: Continuation) =
  if isPoolWorker() or getThreadId() == entryThread:
    submit(grouped(c))
  else:
    # Message handoff to the process runner. A foreign thread never polls a
    # standard lane or runs a passive I/O continuation through caller-runs.
    while not enqueueExternal(external, c): sleepUs(1000)

var gStopReq, gFinished, gActive: int
var gAdmission: TicketLock
var taskAnchor = default(CoroutineBase)
var rootAnchor = default(CoroutineBase)

proc beStopping*(): bool {.inline.} = atomicLoad(gStopReq, moSequentiallyConsistent) != 0

proc admitTask(): bool =
  gAdmission.acquire()
  result = not beStopping() and atomicLoad(gActive, moAcquire) < atomicLoad(gTaskLimit, moRelaxed)
  if result: discard atomicFetchAdd(gActive, 1, moAcquireRelease)
  gAdmission.release()

proc admitCleanupTask(): bool =
  ## Existing resources may need cleanup after stop admission closes. The
  ## runner and this check share the lock, so cleanup cannot enter after drain.
  gAdmission.acquire()
  result = atomicLoad(gFinished, moAcquire) == 0 and
    (not beStopping() or atomicLoad(gActive, moAcquire) > 0 or
      atomicLoad(gResuming, moAcquire) > 0)
  if result: discard atomicFetchAdd(gActive, 1, moAcquireRelease)
  gAdmission.release()

proc finishedTask(frame: ptr CoroutineBase): Continuation {.nimcall.} =
  discard atomicFetchSub(gActive, 1, moAcquireRelease)
  result = default(Continuation)

proc finishedRoot(frame: ptr CoroutineBase): Continuation {.nimcall.} =
  discard atomicFetchSub(gActive, 1, moAcquireRelease)
  result = frame.caller

proc tracked(c: Continuation): Continuation =
  result = c
  result.env[].caller = Continuation(fn: finishedTask, env: addr taskAnchor)

proc beInit*() =
  initIoRing()
  initParked()
  var limit = tasksFromEnv("ZAL_TASKS")
  if limit == 0:
    var soft = 0
    var hard = 0
    if fdLimits(soft, hard): limit = min(max(soft, ExternalCapacity), MaxTasks)
    else: limit = ExternalCapacity
  atomicStore(gTaskLimit, limit, moRelaxed)

proc beStop*() =
  ## Signal-safe request. The process runner performs joining after tasks drain.
  closeServiceAdmission()
  atomicStore(gStopReq, 1, moSequentiallyConsistent)

proc beRun*() =
  ## The main thread alone services the standard foreign lane. Library-owned
  ## tasks retain an admission until their complete passive body has returned.
  var completions = default(array[16, IoCompletion])
  var swept = false
  while true:
    if not swept and beStopping():
      swept = true
      interruptParked()
    gAdmission.acquire()
    let drained = beStopping() and atomicLoad(gActive, moAcquire) == 0 and
      atomicLoad(gResuming, moAcquire) == 0
    gAdmission.release()
    if drained and joinProcessServices(): break
    if beStopping(): discard joinProcessServices()
    var incoming = default(array[64, Continuation])
    let count = dequeueExternal(external, incoming)
    for i in 0..<count: submit(grouped(incoming[i]))
    discard pollCompletions(completions)
    sleepUs(1000)
  shutdown()
  closeWakePool()
  atomicStore(gFinished, 1, moRelease)



proc beWakeAcceptors*(fd: cint) =
  ## The single accept loop polls the listener; the wake connection made by
  ## `stopAccepting` or `closeListener` makes that poll fire. The listener
  ## is not shut down: that would discard the wake connection, and the
  ## epoll fallback does not complete a read poll on the hang-up that
  ## remains. Nothing to acknowledge (`beForgetAcks` is 0).
  discard fd

proc beForgetAcks*(): int {.inline.} = 0

proc beInterruptFd*(fd: cint): bool =
  ## Not on std: std/ioring cannot reach polls pending on other workers.
  discard fd
  result = false

proc beNudgeFd*(fd: cint): bool =
  ## Not on std (as `beInterruptFd`).
  discard fd
  result = false

proc beNeedsPoke*(): bool {.inline.} = true
  ## A poll armed on the listener completes only when it becomes readable.

proc runtimeWorkers*(): int = workerCount
  ## Pool workers. Placement is the pool's: `spawnAll` runs one instance.

proc onLoop*(): bool {.inline.} = isPoolWorker()

template beParkFd*(fd: cint; write, listener: bool; deadline: Deadline; res: var int; sliced = true) =
  block:
    res = -1
    var dir = {evRead}
    if write: dir = {evWrite}
    let until = deadline
    var slice = SliceMs
    while true:
      let cont = delay()
      let step = if not sliced or until <= afterMs(SliceMaxMs): until else: earlier(until, afterMs(slice))
      discard submitPollAdd(fd, step, dir, grouped(cont), addr res)
      suspend()
      if beStopping():
        res = ECancelled
        break
      if res == time.IoTimedOut and monoNow() < until:
        # A polling slice is not readiness. Keep the original deadline so
        # callers with relative idle timeouts cannot restart it every slice.
        slice = min(slice * 2, SliceMaxMs)
        continue
      break
    if res == 0:
      # io_uring always reports the hang-up bits: after the peer's
      # half-close (EPOLLRDHUP) a write poll fires at once, and std/ioring
      # maps a poll that fired only for those bits to 0. Wait a moment and
      # report the direction ready: the caller's next system call tells a
      # writable socket from a broken one, and the pause keeps a socket
      # with a full buffer from spinning while EPOLLRDHUP stays set.
      let pause = delay()
      discard submitTimeout(afterMs(1), grouped(pause))
      suspend()
      res = toEventMask(dir)

template beParkUntil*(deadline: Deadline) =
  block:
    let until = deadline
    var slice = SliceMs
    while not beStopping() and monoNow() < until:
      let cont = delay()
      discard submitTimeout(earlier(until, afterMs(slice)), grouped(cont))
      suspend()
      slice = min(slice * 2, SliceMaxMs)

template beYield*() =
  ## On a worker the continuation is staged on the private ring, flushed only
  ## after this step returns, so it cannot race the suspending frame.
  block:
    let cont = delay()
    if isPoolWorker(): submit(grouped(cont))
    else: discard submitNop(never, grouped(cont))
    suspend()

template beTrySpawn*(call: untyped): bool =
  block:
    let accepted = admitTask()
    if accepted: schedule(tracked(delay(call)))
    accepted

template beTryCleanup*(call: untyped): bool =
  block:
    let accepted = admitCleanupTask()
    if accepted: schedule(tracked(delay(call)))
    accepted

template beSpawn*(call: untyped) =
  discard beTrySpawn(call)

template beTryRoot*(call: untyped; completion: Continuation): bool =
  block:
    let accepted = admitTask()
    if accepted:
      prepareRoot(rootAnchor, completion)
      let rootContinuation: Continuation = delay(call)
      rootContinuation.env[].caller = Continuation(fn: finishedRoot, env: addr rootAnchor)
      schedule(rootContinuation)
    accepted

proc beStartInline*(c: Continuation) =
  # complete now owns a Join; advance preserves our existing completion caller.
  var pending = grouped(c)
  while pending.fn != nil:
    pending = advance(pending)

template beStartConn*(call: untyped) =
  ## Inline until the first park; the pool places the rest.
  if admitTask():
    if isPoolWorker() or getThreadId() == entryThread: beStartInline(tracked(delay(call)))
    else: schedule(tracked(delay(call)))

# ------------------------------------------------------------ wait nodes

proc stageResume(c: Continuation) =
  ## A resume must become visible only after its current passive step returns.
  ## Workers stage on their private ring. The process runner stages through its
  ## own I/O lane, which only that thread polls after returning from this step.
  if isPoolWorker(): submit(grouped(c))
  else:
    assert getThreadId() == entryThread, "passive waits require a pool worker or the process runner"
    discard submitNop(never, grouped(c))

proc beSchedule*(c: Continuation) =
  stageResume(c)

proc bePrepareNode*(n: ptr WaitNode): bool =
  n.ringRes = 0
  result = leaseWake(n.efd, n.efdW)

proc observeNode(n: ptr WaitNode; deadline: Deadline) {.passive.} =
  var slice = SliceMs
  while atomicLoad(n.state, moAcquire) == nsParked:
    let wake = delay()
    discard submitPollAdd(n.efd, earlier(deadline, afterMs(slice)), {evRead}, grouped(wake), addr n.ringRes)
    suspend()
    slice = min(slice * 2, SliceMaxMs)
    if beStopping():
      if tryClaim(n, wrClosed): atomicStore(n.state, nsFired, moRelease)
    elif deadline <= monoNow():
      if tryClaim(n, wrTimedOut): atomicStore(n.state, nsFired, moRelease)
  # A remote winner may still be publishing its result and wake byte.
  while atomicLoad(n.state, moAcquire) != nsFired: cpuRelax()

proc beArmNode*(n: ptr WaitNode; deadline: Deadline) =
  let watcher = delay(observeNode(n, deadline))
  watcher.env[].caller = n.cont
  stageResume(watcher)

proc beSettleNode*(n: ptr WaitNode; armed: bool) =
  ## The watcher returned only after its final readiness completion and claim.
  if armed: drainWake(n.efd)
  returnWake(n.efd, n.efdW)

proc beResumeNode*(n: ptr WaitNode) =
  ## Called once, by the claim winner, from any thread. The waiter may run
  ## as soon as the write lands; it spins until nsFired before touching the
  ## node, and the node is not touched after that store.
  signalWake(n.efdW)
  atomicStore(n.state, nsFired, moRelease)

# ------------------------------------------------------------------ shards

proc beShardCount*(): int = workerCount + 1
  ## One shard per pool worker, plus one shared by every other thread.

proc beShardId*(): int {.inline.} =
  if isPoolWorker(): result = threadIdx
  else: result = workerCount

proc beFinished*(): bool = atomicLoad(gFinished, moAcquire) != 0

template beTryStartConn*(call: untyped): bool =
  block:
    let accepted = admitTask()
    if accepted:
      if isPoolWorker() or getThreadId() == entryThread: beStartInline(tracked(delay(call)))
      else: schedule(tracked(delay(call)))
    accepted
