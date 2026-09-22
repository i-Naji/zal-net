import zal_net/private/runtime
## `parkOn`: the one implementation of the wait protocol's publish, arm,
## suspend and settle steps (see core/waitq.nim). Every in-memory wait is
## built on it.

import std/atomics
import std/ticketlocks
import zal_net/rt
import zal_net/private/core/waitq
import zal_net/private/core/cancelstate
export waitq

template parkOn*(node: var WaitNode; lockp: ptr TicketLock; q: ptr WaitQueue;
                 tok: CancelToken; deadline: Deadline; ready: untyped;
                 consume: untyped = true) =
  ## Inside a passive proc. `ready` observes state under `lockp[]` without
  ## consuming it. Only a successful readiness claim evaluates `consume`,
  ## under the same lock. Cancellation cannot steal a consumed permit.
  block:
    retain(tok)
    node.state = nsParked
    node.res = ord(wrClosed)
    node.qnext = nil
    node.qprev = nil
    node.linked = false
    node.tnext = nil
    node.tprev = nil
    node.hooked = false
    if bePrepareNode(addr node):
      var selfClaimed = false
      node.cont = delay()
      if tok != nil and not hookToken(tok, addr node):
        if tryClaim(addr node, wrCancelled): selfClaimed = true
      if not selfClaimed and atomicLoad(node.state, moAcquire) == nsParked:
        acquire(lockp[])
        if ready:
          if claimReady(addr node, consume):
            selfClaimed = true
        else:
          link(q[], addr node)
        release(lockp[])
      if selfClaimed: beSchedule(node.cont)
      else: beArmNode(addr node, deadline)
      suspend()
      beSettleNode(addr node, not selfClaimed)
      unlinkLocked(lockp, q, addr node)
      if tok != nil: unhookToken(tok, addr node)
    release(tok)
