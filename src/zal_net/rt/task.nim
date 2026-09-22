import zal_net/private/runtime
## Tasks and scopes: structured concurrency on top of the sync primitives.
##
## A task is a passive proc started with `startTask`. Its handle can join it
## (wait for it to finish), cancel it (its token, a child of its scope's), or
## detach from it. A scope counts its live tasks: `waitAll` waits for them,
## and `close(grace)` waits up to `grace`, then cancels the rest and waits for
## them to finish (chronos's cancelAndWait).
##
## Every task, and the scope, must be released by its owner; a running task
## holds its own reference until it finishes.

import std/atomics
import std/ticketlocks
import zal_net/rt
import zal_net/rt/cancel
import zal_net/errors
import zal_net/rt/sync
import zal_net/private/sharedmem

type
  TaskFn* = proc (t: Task; arg: nil pointer): int {.nimcall, passive.}
    ## A task body; its result is the task's result code (`code`). `t`
    ## gives it its token (`token(t)`) for token-aware waits.

  ScopeObj = object
    lock: TicketLock
    refs: int            # atomic
    live: int            # guarded by lock
    closing: bool        # guarded by lock; permanently rejects new children
    idle: Event          # set while no task is live
    tok: CancelToken
  Scope* = ptr ScopeObj

  TaskObj = object
    refs: int            # atomic: the running task + the handle
    done: Event
    tok: CancelToken
    scope: nil Scope
    fn: TaskFn
    arg: nil pointer
    code: int
    admitted: bool          # immutable after startTask returns
  Task* = ptr TaskObj

proc newScope*(parent: nil Scope = nil): Scope =
  ## An empty scope; cancelling the parent cancels it. One reference, the
  ## caller's.
  result = cast[Scope](requireShared(sizeof(ScopeObj)))
  result.refs = 1
  var ptok: nil CancelToken = nil
  if parent != nil: ptok = parent.tok
  result.tok = newCancelToken(ptok)
  setEvent(addr result.idle)

proc token*(s: Scope): CancelToken {.inline.} = s.tok

proc release*(s: nil Scope) =
  if s != nil and atomicFetchSub(s.refs, 1, moAcquireRelease) == 1:
    release(s.tok)
    freeShared(s)

proc cancel*(s: Scope) =
  acquire(s.lock)
  s.closing = true
  release(s.lock)
  cancel(s.tok)

proc enter(s: Scope): bool =
  acquire(s.lock)
  if s.closing or cancelled(s.tok):
    release(s.lock)
    return false
  discard atomicFetchAdd(s.refs, 1, moRelaxed)
  s.live = s.live + 1
  if s.live == 1: clearEvent(addr s.idle)
  release(s.lock)
  result = true

proc leave(s: Scope) =
  acquire(s.lock)
  s.live = s.live - 1
  let empty = s.live == 0
  if empty: setEvent(addr s.idle)
  release(s.lock)
  release(s)

proc waitAll*(s: Scope; d: Deadline): WaitResult {.passive.} =
  ## Wait until the scope has no live task.
  result = wait(addr s.idle, d)

proc close*(s: Scope; grace: Deadline): WaitResult {.passive.} =
  ## Wait up to `grace` for the tasks; then cancel the rest and wait for
  ## them. wrReady when they finished on their own, wrCancelled otherwise.
  acquire(s.lock)
  s.closing = true
  release(s.lock)
  result = wait(addr s.idle, grace)
  if result != wrReady:
    cancel(s.tok)
    # Runtime shutdown may wake a wait without completing its children.
    # Completion, rather than a cancellation acknowledgement, owns teardown.
    while not isSet(addr s.idle):
      discard wait(addr s.idle, never)
      if not isSet(addr s.idle): yieldNow()
    result = wrCancelled

proc release*(t: nil Task) =
  if t != nil and atomicFetchSub(t.refs, 1, moAcquireRelease) == 1:
    release(t.tok)
    freeShared(t)

proc finish(t: Task) =
  setEvent(addr t.done)
  let s = t.scope
  if s != nil: leave(s)
  release(t)

proc taskMain(t: Task) {.passive.} =
  t.code = t.fn(t, t.arg)
  finish(t)

proc startTask*(fn: TaskFn; arg: nil pointer; scope: nil Scope = nil): Task =
  ## Start `fn(task, arg)` on this loop (on the std backend, on the pool).
  ## Returns the handle; release it when done. After shutdown the body does not
  ## run: the returned handle is finished/cancelled with code ResourceClosed;
  ## the caller retains arg and any resources the body would have consumed.
  result = cast[Task](requireShared(sizeof(TaskObj)))
  result.refs = 2
  result.fn = fn
  result.arg = arg
  result.scope = scope
  var ptok: nil CancelToken = nil
  if scope != nil:
    ptok = scope.tok
    if not enter(scope):
      result.scope = nil
      result.tok = newCancelToken(ptok)
      result.code = ResourceClosed
      cancel(result.tok)
      finish(result)
      return
  result.tok = newCancelToken(ptok)
  result.admitted = true
  if not trySpawnTask(taskMain(result)):
    result.admitted = false
    result.code = ResourceClosed
    cancel(result.tok)
    finish(result)

proc token*(t: Task): CancelToken {.inline.} = t.tok
proc admitted*(t: Task): bool {.inline.} = t.admitted
  ## Whether the body accepted ownership of arg, independently of its result.
proc cancelled*(t: Task): bool {.inline.} = cancelled(t.tok)
proc cancel*(t: Task) = cancel(t.tok)
proc finished*(t: Task): bool = isSet(addr t.done)
proc code*(t: Task): int {.inline.} = t.code
  ## The body's result, once `finished`.

proc join*(t: Task; d: Deadline; tok: nil CancelToken = nil): WaitResult {.passive.} =
  ## Wait for the task to finish.
  result = wait(addr t.done, d, tok)

proc cancelAndJoin*(t: Task; d: Deadline): WaitResult {.passive.} =
  cancel(t.tok)
  result = wait(addr t.done, d)

proc sleepUntil*(d: Deadline; tok: CancelToken): WaitResult {.passive.} =
  ## A sleep that a cancel ends early: wrTimedOut when `d` passed (the
  ## normal outcome), wrCancelled when the token fired first.
  var n = default(Notify)
  result = wait(addr n, d, tok)
