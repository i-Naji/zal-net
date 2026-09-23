## Synchronized admission and draining for retained stream owners.
## The enclosing reference owns the descriptor and retains this stable state.
import zal_net/[rt, errors], zal_net/rt/sync
import std/ticketlocks
when not defined(gcAtomicArc):
  {.error: "Standard runtime owners require --mm:atomicArc".}
type OwnerState* = enum
  ownerClosed, ownerOpen, ownerClosing

type OwnerLife* = object
  lock: TicketLock
  cleanupClaimed, interrupting, exclusive: bool
  controls: int
  phase: OwnerState
  reading, writing: bool
  idle: Event                    ## borrowers acknowledged; cleanup may remain
  closed: Event                  ## final resource release, independent wait

proc initOwnerLife*(life: var OwnerLife) =
  life.phase = ownerOpen
  setEvent(addr life.idle)
  clearEvent(addr life.closed)

proc state*(life: var OwnerLife): OwnerState =
  life.lock.acquire()
  result = life.phase
  life.lock.release()
proc isIdle*(life: var OwnerLife): bool =
  life.lock.acquire()
  result = not life.reading and not life.writing and life.controls == 0
  life.lock.release()

proc beginBorrow*(life: var OwnerLife; write: bool): int =
  life.lock.acquire()
  if life.phase != ownerOpen: result = ResourceClosed
  elif life.exclusive: result = ResourceBusy
  elif (write and life.writing) or (not write and life.reading): result = ResourceBusy
  else:
    if write: life.writing = true
    else: life.reading = true
    result = 0
  life.lock.release()

proc endBorrow*(life: var OwnerLife; write: bool) =
  life.lock.acquire()
  if write: life.writing = false
  else: life.reading = false
  life.lock.release()

proc signalIdle*(life: var OwnerLife) =
  life.lock.acquire()
  if life.phase == ownerClosing and not life.reading and not life.writing and life.controls == 0:
    setEvent(addr life.idle)
  life.lock.release()

proc beginClose*(life: var OwnerLife; holdInterrupt = false; requireIdle = false): int =
  life.lock.acquire()
  result = 0
  if life.phase == ownerOpen and requireIdle and
      (life.reading or life.writing or life.controls != 0):
    result = ResourceBusy
  elif life.phase == ownerOpen:
    clearEvent(addr life.idle)
    clearEvent(addr life.closed)
    life.phase = ownerClosing
    life.interrupting = holdInterrupt
  elif holdInterrupt:
    result = ResourceClosed # No second interruption owner.
  life.lock.release()

proc reopenRejectedClose*(life: var OwnerLife) =
  ## Synchronous disposal rejected before consumption; restore the source.
  life.lock.acquire()
  life.phase = ownerOpen
  life.cleanupClaimed = false
  life.interrupting = false
  setEvent(addr life.closed)
  life.lock.release()

proc finishInterrupt*(life: var OwnerLife) =
  life.lock.acquire()
  life.interrupting = false
  life.lock.release()

proc claimOwnerCleanup*(life: var OwnerLife): bool =
  life.lock.acquire()
  result = life.phase == ownerClosing and not life.reading and not life.writing and life.controls == 0 and
    not life.cleanupClaimed and not life.interrupting
  if result: life.cleanupClaimed = true
  life.lock.release()

proc beginControl*(life: var OwnerLife): int =
  life.lock.acquire()
  if life.phase == ownerClosed or life.cleanupClaimed: result = ResourceClosed
  elif life.exclusive: result = ResourceBusy
  else:
    inc life.controls
    result = 0
  life.lock.release()

proc beginExclusiveControl*(life: var OwnerLife): int =
  life.lock.acquire()
  if life.phase != ownerOpen: result = ResourceClosed
  elif life.reading or life.writing or life.controls != 0: result = ResourceBusy
  else:
    life.exclusive = true
    life.controls = 1
    result = 0
  life.lock.release()

proc releaseCleanupClaim*(life: var OwnerLife) =
  life.lock.acquire()
  life.cleanupClaimed = false
  life.lock.release()

proc endControl*(life: var OwnerLife) =
  life.lock.acquire()
  dec life.controls
  if life.controls == 0: life.exclusive = false
  life.lock.release()

proc beginTransfer*(life: var OwnerLife): int =
  ## Caller validates destination before this point. Admission invalidates aliases.
  life.lock.acquire()
  if life.phase != ownerOpen: result = ResourceClosed
  elif life.reading or life.writing or life.controls != 0: result = ResourceBusy
  else:
    life.phase = ownerClosed
    life.cleanupClaimed = true
    result = 0
  life.lock.release()

proc markClosed*(life: var OwnerLife) =
  life.lock.acquire()
  life.phase = ownerClosed
  setEvent(addr life.idle)
  setEvent(addr life.closed)
  life.lock.release()

proc idleEvent(life: var OwnerLife): ptr Event {.inline.} =
  # The pin loses private-field resolution inside nested templates. Keep field
  # addressing in a typed proc; ttcpref/tunixref guard both caller expansions.
  addr life.idle

proc closedEvent(life: var OwnerLife): ptr Event {.inline.} =
  addr life.closed

template drainClose*(life: ptr OwnerLife; deadline: Deadline): int =
  # Expand in the retaining caller's frame; no additional passive entry.
  block:
    let gate = life
    var code = 0
    while state(gate[]) != ownerClosed:
      if state(gate[]) == ownerOpen:
        code = ResourceBusy
        break
      let outcome = wait(closedEvent(gate[]), deadline)
      if state(gate[]) == ownerClosed: break
      if outcome == wrTimedOut:
        code = IoTimedOut
        break
      # Runtime shutdown can wake an uncompleted wait; it must not free state.
      yieldNow()
    code

template drainBorrowers*(life: ptr OwnerLife) =
  ## Cleanup owns the enclosing reference and cannot abandon outstanding I/O.
  block:
    let gate = life
    while not isIdle(gate[]):
      discard wait(idleEvent(gate[]), never)
      if not isIdle(gate[]): yieldNow()
