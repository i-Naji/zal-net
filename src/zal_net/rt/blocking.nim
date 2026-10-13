## The blocking pool: regular procs that must not run on a loop (getaddrinfo,
## databases, files, password hashing) run here, on a few dedicated threads.
##
## A job is one heap allocation. Embed `Job` as the first field of an object
## holding the job's inputs and results, allocate it with `newJob`, submit it
## with `spawnBlocking`, and wait for it with `awaitJob`. The worker writes
## only into the job; a waiter that times out or is cancelled marks the job
## abandoned and the pool frees it later, so no thread ever writes into a
## frame that may be gone.
##
## Threads with their own poller (the UDP engine) collect finished jobs from a
## `JobInbox` instead of awaiting them.

import std/atomics
import std/syncio
import std/ticketlocks
import std/locks
import zal_net/rt
import zal_net/private/services
import zal_net/rt/sync
import zal_net/private/core/eventcount
import zal_net/private/core/mailbox
import zal_net/private/sys/threads
import zal_net/private/sys/env
import zal_net/private/sys/sock

const
  jsQueued = 0
  jsRunning = 1
  jsDone = 2
  jsAbandoned = 3

type
  JobFn* = proc (j: ptr Job) {.nimcall.}
    ## Runs on a blocking thread: regular code only.

  Job* = object
    node*: MailNode          # link in the pool queue or an inbox
    fn: JobFn
    refs: int                # atomic
    state: int               # atomic
    done: Notify
    onDrop: nil JobFn       # result could not be delivered to its consumer
    dispose: nil JobFn       # final resource cleanup, on whichever thread releases last
    inbox: nil InboxPtr  # where a finished job goes; nil: its waiter
    tag*, tag2*: uint64      # caller data, for inbox consumers

  InboxState = object
    refs: int
    lock: Lock
    closed: bool
    box: Mailbox
    queued: int
    wakeRd, wakeWr: cint
  InboxPtr = ptr InboxState

  JobInbox* = object
    ## Consumer-owned handle. Producers retain the shared state, not this
    ## wrapper. Close detaches the consumer; late results are safely discarded.
    gate: TicketLock
    state: nil InboxPtr

  JobPtr* = ptr Job
  JobInboxPtr* = ptr JobInbox

proc cCalloc(n, size: csize_t): nil pointer {.importc: "calloc", header: "<stdlib.h>".}
proc cFree(p: nil pointer) {.importc: "free", header: "<stdlib.h>".}
var liveInboxes: int
var liveJobs: int

proc liveJobInboxes*(): int = atomicLoad(liveInboxes, moRelaxed)
proc liveBlockingJobs*(): int = atomicLoad(liveJobs, moRelaxed)

proc releaseInbox(b: InboxPtr) =
  if atomicFetchSub(b.refs, 1, moAcquireRelease) == 1:
    wakeClose(b.wakeRd, b.wakeWr)
    deinitLock(b.lock)
    discard atomicFetchSub(liveInboxes, 1, moRelaxed)
    cFree(b)

proc retainInbox(b: JobInboxPtr): nil InboxPtr =
  acquire(b.gate)
  let state = b.state
  if state != nil: discard atomicFetchAdd(state.refs, 1, moRelaxed)
  result = state
  release(b.gate)

var gPoolLock: TicketLock
var gHead, gTail: nil ptr Job   # the queue, through node.next
var gQueued: int
var gMaxQueued = 4096
var gPoolState: int          # atomic: 0 none, 1 starting, 2 running, 3 joined
let gWake = newEventCount()
var gWorkers: array[MaxWorkers, ThreadHandle]
var gWorkerCount: int
var gActiveWorkers: int
var gPoolClosing: int

proc newJob*(size: int; fn: JobFn; dispose: nil JobFn = nil; onDrop: nil JobFn = nil): JobPtr =
  ## Zeroed memory of `size` bytes (at least `sizeof(Job)`); one reference,
  ## the caller's.
  let mem = cCalloc(1, csize_t(max(size, sizeof(Job))))
  if mem == nil: quit "zal-net: out of memory (blocking job)"
  result = cast[JobPtr](mem)
  result.dispose = dispose
  result.onDrop = onDrop
  discard atomicFetchAdd(liveJobs, 1, moRelaxed)
  result.fn = fn
  result.refs = 1

proc releaseJob*(j: nil ptr Job) =
  if j != nil and atomicFetchSub(j.refs, 1, moAcquireRelease) == 1:
    let dispose = j.dispose
    if dispose != nil: dispose(j)
    discard atomicFetchSub(liveJobs, 1, moRelaxed)
    cFree(j)

proc deliver(b: InboxPtr; j: JobPtr; maxQueued = 0): bool =
  ## Consume the producer's inbox and job references in both outcomes.
  acquire(b.lock)
  result = not b.closed and (maxQueued <= 0 or b.queued < maxQueued)
  if result:
    b.queued = b.queued + 1
    if push(b.box, addr j.node): wakeSignal(b.wakeWr)
  release(b.lock)
  if not result:
    let drop = j.onDrop
    if drop != nil: drop(j)
    releaseJob(j)
  releaseInbox(b)


proc takeJob(): nil ptr Job =
  {.cast(assumeSync).}:
    acquire(gPoolLock)
    let j = gHead
    if j != nil:
      let next = cast[nil ptr Job](j.node.next)
      gHead = next
      if next == nil: gTail = nil
      j.node.next = nil
      gQueued = gQueued - 1
    release(gPoolLock)
    result = j

proc blockingMain(arg: nil pointer) {.nimcall.} =
  while true:
    var j = takeJob()
    if j == nil:
      if atomicLoad(gPoolClosing, moAcquire) != 0: break
      let t = prepareWait(gWake)
      j = takeJob()
      if j == nil:
        if atomicLoad(gPoolClosing, moAcquire) != 0:
          cancelWait(gWake)
          break
        commitWait(gWake, t)
        continue
      cancelWait(gWake)
    var expected = jsQueued
    if atomicCompareExchange(j.state, expected, jsRunning, moAcquireRelease, moAcquire):
      j.fn(j)
      var running = jsRunning
      if atomicCompareExchange(j.state, running, jsDone, moAcquireRelease, moAcquire):
        let box = j.inbox
        if box != nil:
          # Deliver consumes both producer references, including after close.
          j.inbox = nil
          discard deliver(box, j)
          continue
        notifyOne(addr j.done)
    let abandonedBox = j.inbox
    j.inbox = nil
    if abandonedBox != nil: releaseInbox(abandonedBox)
    releaseJob(j)

  discard atomicFetchSub(gActiveWorkers, 1, moRelease)

proc stopBlockingPool*()
proc joinBlockingPool*(): bool

proc initBlockingPool*(threads = 0; maxQueued = 4096) =
  {.cast(assumeSync).}:
    ## Start the pool: `threads`, else NN_BLOCKING_THREADS, else 4. Called
    ## on first use; idempotent.
    if atomicLoad(gPoolState, moAcquire) >= 2: return
    var expected = 0
    if not atomicCompareExchange(gPoolState, expected, 1, moAcquireRelease, moAcquire):
      while atomicLoad(gPoolState, moAcquire) == 1: discard
      return
    gMaxQueued = maxQueued
    var n = threads
    if n <= 0: n = workersFromEnv("NN_BLOCKING_THREADS")
    if n <= 0: n = 4
    n = min(n, gWorkers.len)
    var i = 0
    while i < n:
      discard atomicFetchAdd(gActiveWorkers, 1, moRelaxed)
      if not startJoinable(gWorkers[i], blockingMain, nil):
        discard atomicFetchSub(gActiveWorkers, 1, moRelaxed)
        break
      i = i + 1
    gWorkerCount = i
    if i == 0:
      atomicStore(gPoolClosing, 1, moRelease)
    atomicStore(gPoolState, 2, moRelease)

proc spawnBlocking*(j: ptr Job; inbox: nil ptr JobInbox = nil): bool =
  {.cast(assumeSync).}:
    ## Queue `j` (the pool takes its own reference). False when the queue is
    ## full: the caller may retry later or fail the request.
    initBlockingPool()
    var box: nil InboxPtr = nil
    if inbox != nil:
      box = retainInbox(inbox)
      if box == nil: return false
    j.inbox = box
    j.state = jsQueued
    acquire(gPoolLock)
    if gQueued >= gMaxQueued or atomicLoad(gPoolClosing, moAcquire) != 0:
      release(gPoolLock)
      j.inbox = nil
      if box != nil: releaseInbox(box)
      return false
    discard atomicFetchAdd(j.refs, 1, moRelaxed)
    j.node.next = nil
    let t = gTail
    if t == nil: gHead = j
    else: t.node.next = addr j.node
    gTail = j
    gQueued = gQueued + 1
    # Serialize the wake with shutdown: the last worker may already have
    # drained this job before the submitting thread gets here.
    notifyOne(gWake)
    release(gPoolLock)
    result = true

proc awaitJob*(j: ptr Job; d: Deadline; tok: nil CancelToken = nil): WaitResult {.passive.} =
  ## Wait for `j` to finish. On a timeout or cancel the job is abandoned: it
  ## is skipped if it had not started, and its result is dropped otherwise.
  ## Either way the caller still releases its own reference.
  result = wait(addr j.done, d, tok)
  if result != wrReady:
    var s = atomicLoad(j.state, moAcquire)
    while s == jsQueued or s == jsRunning:
      if atomicCompareExchange(j.state, s, jsAbandoned, moAcquireRelease, moAcquire): return
    if s == jsDone: result = wrReady   # it finished while we gave up

proc postJob*(box: JobInboxPtr; j: JobPtr; maxQueued = 0): bool =
  ## Post without running. False means closed or at maxQueued (0: unlimited).
  ## The caller keeps its reference in either case. A successful consumer owns one extra reference.
  let state = retainInbox(box)
  if state == nil: return false
  atomicStore(j.state, jsDone, moRelease)
  discard atomicFetchAdd(j.refs, 1, moRelaxed)
  j.node.next = nil
  result = deliver(state, j, maxQueued)

proc initJobInbox*(b: var JobInbox): bool =
  if b.state != nil: return false
  let mem = cCalloc(1, csize_t(sizeof(InboxState)))
  if mem == nil: return false
  let state = cast[InboxPtr](mem)
  state.wakeRd = -1
  state.wakeWr = -1
  if not wakePair(state.wakeRd, state.wakeWr):
    cFree(state)
    return false
  initLock(state.lock)
  state.refs = 1
  b.state = state
  discard atomicFetchAdd(liveInboxes, 1, moRelaxed)
  result = true

proc inboxFd*(b: JobInbox): cint =
  let state = b.state
  if state == nil: return -1
  result = state.wakeRd

proc closeJobInbox*(b: var JobInbox) =
  ## Consumer only, after it stopped polling. Idempotent. Pending producers may
  ## finish later; they never touch this wrapper or the former consumer.
  acquire(b.gate)
  let state = b.state
  b.state = nil
  release(b.gate)
  if state == nil: return
  acquire(state.lock)
  state.closed = true
  var node = takeAll(state.box)
  state.queued = 0
  release(state.lock)
  while node != nil:
    let next = node.next
    let job = cast[JobPtr](node)
    let drop = job.onDrop
    if drop != nil: drop(job)
    releaseJob(job)
    node = next
  releaseInbox(state)

proc takeCompleted*(b: var JobInbox): nil JobPtr =
  let state = b.state
  if state == nil: return nil
  acquire(state.lock)
  wakeDrain(state.wakeRd)
  result = cast[nil JobPtr](takeAll(state.box))
  state.queued = 0
  release(state.lock)

proc nextJob*(j: ptr Job): nil ptr Job {.inline.} = cast[nil ptr Job](j.node.next)

proc stopBlockingPool*() =
  ## Stop submissions; queued jobs drain and running calls finish. Nonblocking.
  ## Call after stopping job-producing services. The pool cannot restart.
  # Claim an unused pool without starting workers just to stop them. If an
  # initializer won the race, wait until its worker count has been published.
  var expected = 0
  let unused = atomicCompareExchange(gPoolState, expected, 1, moAcquireRelease, moAcquire)
  if not unused:
    while atomicLoad(gPoolState, moAcquire) == 1: discard
  acquire(gPoolLock)
  atomicStore(gPoolClosing, 1, moRelease)
  if unused: atomicStore(gPoolState, 2, moRelease)
  if atomicLoad(gPoolState, moAcquire) == 2: notifyAll(gWake)
  release(gPoolLock)

proc blockingPoolClosing*(): bool =
  ## Submissions are permanently closed even while existing calls drain.
  atomicLoad(gPoolClosing, moAcquire) != 0

proc blockingPoolStopped*(): bool =
  atomicLoad(gPoolClosing, moAcquire) != 0 and atomicLoad(gActiveWorkers, moAcquire) == 0

proc joinBlockingPool*(): bool =
  {.cast(assumeSync).}:
    ## Control-thread only. False while an OS call or queued job is still running;
    ## retry later. Never force-free a worker's memory. True is idempotent.
    acquire(gPoolLock)
    if atomicLoad(gPoolState, moAcquire) == 3:
      release(gPoolLock)
      return true
    if not blockingPoolStopped():
      release(gPoolLock)
      return false
    var i = 0
    while i < gWorkerCount:
      if not joinThread(gWorkers[i]):
        release(gPoolLock)
        return false
      i = i + 1
    freeEventCount(gWake)
    atomicStore(gPoolState, 3, moRelease)
    release(gPoolLock)
    result = true

if not registerProcessService(stopBlockingPool, joinBlockingPool):
  freeEventCount(gWake)
  atomicStore(gPoolClosing, 1, moRelease)
  atomicStore(gPoolState, 3, moRelease)
