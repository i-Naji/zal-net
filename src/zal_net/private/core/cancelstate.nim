import zal_net/private/runtime
## Cancel tokens. Cancelling one wakes every wait hooked to it with
## `wrCancelled`, shuts down every socket adopted by it, and cancels its
## children. `cancel` is idempotent and callable from any thread.
##
## Nimony has no unwinding: a task that parks elsewhere notices the
## cancellation at its next token-aware wait, or by checking `cancelled`.

import std/atomics
import std/ticketlocks
import zal_net/private/core/waitq
import zal_net/rt

import zal_net/private/sys/sock
import zal_net/private/sharedmem

var liveTokens: int
proc liveCancelTokens*(): int = atomicLoad(liveTokens, moRelaxed)

when not defined(release):
  var tokenAllocationCalls: int
  proc cancelTokenAllocations*(): int = atomicLoad(tokenAllocationCalls, moRelaxed)
    ## Debug-only cumulative counter; a live count alone cannot detect churn.

type
  CancelObj = object
    lock: TicketLock
    state: int                  # atomic: 0 live, 1 cancelled
    refs: int                   # atomic
    head: nil ptr WaitNode      # hooked waits, through tnext/tprev
    fds: unchecked ptr UncheckedArray[cint]   # set while fdCap > 0
    fdLen, fdCap: int
    parent: nil ptr CancelObj
    child, sibling: nil ptr CancelObj   # children, guarded by this token's lock
  CancelToken* = ptr CancelObj

when defined(nnCancelRaceProbe):
  var onFinalChildRelease*: nil proc (parent: CancelToken) {.nimcall.}
    ## Test-only interleaving at the final child release. The fixed path has
    ## already removed the child under its parent's lock at this point.

proc retain*(t: nil CancelToken) =
  if t != nil: discard atomicFetchAdd(t.refs, 1, moRelaxed)

proc cancelled*(t: nil CancelToken): bool {.inline.} =
  ## False for nil.
  result = t != nil and atomicLoad(t.state, moAcquire) != 0

proc newCancelToken*(parent: nil CancelToken = nil): CancelToken =
  ## A live token; it is cancelled with its parent. The caller holds one
  ## reference.
  when not defined(release):
    discard atomicFetchAdd(tokenAllocationCalls, 1, moRelaxed)
  result = cast[CancelToken](requireShared(sizeof(CancelObj)))
  discard atomicFetchAdd(liveTokens, 1, moRelaxed)
  result.refs = 1
  if parent != nil:
    retain(parent)
    result.parent = parent
    acquire(parent.lock)
    result.sibling = parent.child
    parent.child = result
    let dead = atomicLoad(parent.state, moAcquire) != 0
    if dead: atomicStore(result.state, 1, moRelease)
    release(parent.lock)

proc detachChildLocked(parent, child: CancelToken) =
  ## Parent lock also guards the final decrement of every linked child.
  let first = parent.child
  if first == child:
    parent.child = child.sibling
  else:
    var c = first
    while c != nil and c.sibling != child: c = c.sibling
    if c != nil: c.sibling = child.sibling

proc release*(t: nil CancelToken) =
  ## Drop a reference; the last one frees the token. Nothing may still be
  ## hooked to it.
  if t == nil: return
  let parent = t.parent
  if parent != nil:
    # A canceller may retain children only while holding this lock. Remove
    # the final reference and list membership together, never exposing zero
    # references in the list for a canceller to resurrect.
    acquire(parent.lock)
    let last = atomicFetchSub(t.refs, 1, moAcquireRelease) == 1
    if last: detachChildLocked(parent, t)
    release(parent.lock)
    if not last: return
    when defined(nnCancelRaceProbe):
      let probe = onFinalChildRelease
      if probe != nil: probe(parent)
    release(parent)
  elif atomicFetchSub(t.refs, 1, moAcquireRelease) != 1:
    return
  let fds = t.fds
  if fds != nil: freeShared(fds)
  discard atomicFetchSub(liveTokens, 1, moRelaxed)
  freeShared(t)

proc cancel*(t: nil CancelToken) =
  if t == nil: return
  var expected = 0
  if not atomicCompareExchange(t.state, expected, 1, moAcquireRelease, moAcquire): return
  acquire(t.lock)
  var woken: nil ptr WaitNode = nil
  var last: nil ptr WaitNode = nil
  while true:
    let n = t.head
    if n == nil: break
    let nx = n.tnext
    t.head = nx
    if nx != nil: nx.tprev = nil
    n.tnext = nil
    n.tprev = nil
    n.hooked = false
    if tryClaim(n, wrCancelled):
      # The claimed node is ours until resumed: chain it through tnext.
      if last == nil: woken = n
      else: last.tnext = n
      last = n
  var i = 0
  while i < t.fdLen:
    discard sockShutdown(t.fds[i], 2.cint)
    i = i + 1
  var kids: seq[CancelToken] = @[]
  var c = t.child
  while c != nil:
    retain(c)
    kids.add c
    c = c.sibling
  release(t.lock)
  # Resume outside the lock; read each link before its waiter can run.
  var n = woken
  while n != nil:
    let next = n.tnext
    n.tnext = nil
    beResumeNode(n)
    n = next
  for k in kids:
    cancel(k)
    release(k)

proc hookToken*(t: CancelToken; n: ptr WaitNode): bool =
  ## Publish a parked node on the token; false when it is already cancelled.
  acquire(t.lock)
  if atomicLoad(t.state, moAcquire) != 0:
    release(t.lock)
    return false
  let h = t.head
  n.tprev = nil
  n.tnext = h
  if h != nil: h.tprev = n
  t.head = n
  n.hooked = true
  release(t.lock)
  result = true

proc unhookToken*(t: CancelToken; n: ptr WaitNode) =
  acquire(t.lock)
  if n.hooked:
    let p = n.tprev
    let nx = n.tnext
    if p == nil: t.head = nx
    else: p.tnext = nx
    if nx != nil: nx.tprev = p
    n.tnext = nil
    n.tprev = nil
    n.hooked = false
  release(t.lock)

proc adoptFd*(t: nil CancelToken; fd: cint) =
  ## Shut `fd` down when `t` is cancelled; at once if it already is. Call
  ## `releaseFd` before closing the descriptor.
  if t == nil or fd < 0: return
  acquire(t.lock)
  if atomicLoad(t.state, moAcquire) != 0:
    release(t.lock)
    discard sockShutdown(fd, 2.cint)
    return
  if t.fdLen == t.fdCap:
    let cap = if t.fdCap == 0: 4 else: t.fdCap * 2
    let a = cast[ptr UncheckedArray[cint]](requireShared(cap * sizeof(cint)))
    let old = t.fds
    if old != nil:
      copyMem(addr a[0], addr old[0], t.fdLen * sizeof(cint))
      freeShared(old)
    t.fds = a
    t.fdCap = cap
  t.fds[t.fdLen] = fd
  t.fdLen = t.fdLen + 1
  release(t.lock)

proc releaseFd*(t: nil CancelToken; fd: cint) =
  if t == nil: return
  acquire(t.lock)
  var i = 0
  while i < t.fdLen:
    if t.fds[i] == fd:
      t.fdLen = t.fdLen - 1
      t.fds[i] = t.fds[t.fdLen]
      break
    i = i + 1
  release(t.lock)
