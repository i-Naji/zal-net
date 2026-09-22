## The wait protocol shared by every in-memory wait (Notify, Event, Chan,
## Oneshot, join, cancellable sleep).
##
## A `WaitNode` lives in the waiting passive proc's frame. The waiter fills in
## its continuation, marks it parked, then publishes it: into its cancel
## token's list (under the token's lock) and into a wait queue (under that
## queue's lock). Whoever wakes it — a notifier, the node's timer, a canceller,
## or the waiter itself when the condition already holds — must first win
## `tryClaim`, a single compare-and-swap from parked to claimed. Only the
## winner writes the result and resumes the waiter, through the backend.
##
## Rules:
## - Lock order: token lock before queue lock. Never take a token lock while
##   holding a queue lock.
## - Whoever holds a list's lock may unlink any node from that list; the
##   `linked`/`hooked` flags record membership and are read under the lock.
## - A claimed waiter cannot resume until its claimer resumes it, so its
##   frame stays valid for the claimer until then. After resuming, the waiter
##   unlinks itself from every list under the lists' locks, and only then may
##   its frame go away.

import std/atomics
import std/ticketlocks

type
  WaitResult* = enum
    wrReady      ## the condition holds
    wrTimedOut   ## the deadline passed
    wrCancelled  ## the cancel token fired
    wrClosed     ## the object was closed, or the wait could not be set up

const
  nsIdle* = 0
  nsParked* = 1
  nsClaimed* = 2
  nsFired* = 3     ## the claimer's wake write is done

type
  WaitNode* = object
    state*: int            # atomic
    res*: int              # WaitResult, written by the claim winner only
    cont*: Continuation
    qnext*, qprev*: nil ptr WaitNode   # guarded by the queue's lock
    linked*: bool
    tnext*, tprev*: nil ptr WaitNode   # guarded by the token's lock
    hooked*: bool
    efd*, efdW*: cint      # leased wake descriptor (read, write)
    ringRes*: int          # result of the poll on `efd`

  WaitQueue* = object
    head*, tail*: nil ptr WaitNode

proc tryClaim*(n: ptr WaitNode; res: WaitResult): bool {.inline.} =
  result = false
  var expected = nsParked
  if atomicCompareExchange(n.state, expected, nsClaimed, moAcquireRelease, moAcquire):
    n.res = ord(res)
    result = true

template claimReady*(n: ptr WaitNode; consume: untyped): bool =
  ## Queue lock is held. A losing waiter must not consume a ready resource.
  block:
    let won = tryClaim(n, wrReady)
    if won: discard consume
    won

proc link*(q: var WaitQueue; n: ptr WaitNode) =
  ## FIFO append. Caller holds the queue's lock.
  let t = q.tail
  n.qnext = nil
  n.qprev = t
  if t == nil: q.head = n
  else: t.qnext = n
  q.tail = n
  n.linked = true

proc unlink*(q: var WaitQueue; n: ptr WaitNode) =
  ## Caller holds the queue's lock. A no-op when `n` is not linked.
  if not n.linked: return
  let p = n.qprev
  let nx = n.qnext
  if p == nil: q.head = nx
  else: p.qnext = nx
  if nx == nil: q.tail = p
  else: nx.qprev = p
  n.qnext = nil
  n.qprev = nil
  n.linked = false

proc unlinkLocked*(lock: ptr TicketLock; q: ptr WaitQueue; n: ptr WaitNode) =
  acquire(lock[])
  unlink(q[], n)
  release(lock[])

proc claimFirst*(q: var WaitQueue; res: WaitResult): nil ptr WaitNode =
  ## Unlink nodes from the front until one is claimed; nil when none was.
  ## Caller holds the queue's lock and resumes the result after releasing it.
  result = nil
  while true:
    let n = q.head
    if n == nil: break
    unlink(q, n)
    if tryClaim(n, res): return n

proc claimAll*(q: var WaitQueue; res: WaitResult): nil ptr WaitNode =
  ## Unlink every node and claim those still parked; the claimed ones are
  ## returned as a list through `qnext`. Caller holds the queue's lock.
  result = nil
  var last: nil ptr WaitNode = nil
  while true:
    let n = q.head
    if n == nil: break
    unlink(q, n)
    if tryClaim(n, res):
      if last == nil: result = n
      else: last.qnext = n
      last = n
