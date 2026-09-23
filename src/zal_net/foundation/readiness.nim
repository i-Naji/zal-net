## Retained readiness registrations for a serialized consumer.
## Each registration owns one passive waiter. Retirement stops rearming; the
## descriptor owner must join it before closing or reusing the native handle.
import std/[atomics, ticketlocks, tables]
import zal_net/rt
import zal_net/rt/sync

type
  Registration* = ref object
    descriptor: cint
    tag: uint64
    active: int
    rearm, done: Event
    next: nil Registration
  ReadyEvent* = object
    registration*: nil Registration
    tag*: uint64
  Readiness* = ref object
    lock: TicketLock
    first, last: nil Registration
    available: Event
    # Only the serialized consumer accesses this registry.
    registrations: Table[cint, Registration]

proc newReadiness*(): Readiness = Readiness()
proc active*(registration: Registration): bool =
  atomicLoad(registration.active, moAcquire) != 0
proc descriptor*(registration: Registration): cint = registration.descriptor
proc completed*(registration: Registration): bool = isSet(addr registration.done)
proc acknowledge*(registration: Registration) = setEvent(addr registration.rearm)

proc publish(readiness: Readiness; registration: Registration) =
  readiness.lock.acquire()
  let last = readiness.last
  if last == nil: readiness.first = registration
  else: last.next = registration
  readiness.last = registration
  setEvent(addr readiness.available)
  readiness.lock.release()

proc observe(readiness: sink Readiness; registration: sink Registration) {.passive.} =
  while active(registration) and not stopping():
    var outcome = 0
    parkPoll(registration.descriptor, {evRead}, afterMs(10), outcome)
    if not active(registration) or stopping(): break
    if outcome == IoTimedOut: continue
    clearEvent(addr registration.rearm)
    publish(readiness, registration)
    # At most one queued event per registration. Do not resubmit a level-ready
    # socket until its consumer has drained a batch and acknowledged the event.
    while active(registration) and not isSet(addr registration.rearm) and not stopping():
      discard wait(addr registration.rearm, afterMs(10))
  setEvent(addr registration.done)

proc watch*(readiness: Readiness; fd: cint; tag: uint64): bool =
  ## Consumer only. Failure preserves ownership of fd.
  if fd < 0 or readiness.registrations.hasKey(fd): return false
  let registration = Registration(descriptor: fd, tag: tag, active: 1)
  if not trySpawnTask(observe(readiness, registration)): return false
  readiness.registrations[fd] = registration
  result = true

proc retire*(readiness: Readiness; fd: cint): nil Registration =
  ## Consumer only. The returned waiter still borrows fd until completed.
  if not readiness.registrations.hasKey(fd): return nil
  let registration = readiness.registrations.getOrQuit(fd)
  readiness.registrations.del(fd)
  atomicStore(registration.active, 0, moRelease)
  acknowledge(registration)
  result = registration

proc retireAll*(readiness: Readiness): seq[Registration] =
  result = @[]
  for fd, registration in readiness.registrations:
    atomicStore(registration.active, 0, moRelease)
    acknowledge(registration)
    result.add registration
  readiness.registrations.clear()

proc pop(readiness: Readiness): ReadyEvent =
  result = default(ReadyEvent)
  readiness.lock.acquire()
  let first = readiness.first
  if first != nil:
    readiness.first = first.next
    first.next = nil
    if readiness.first == nil:
      readiness.last = nil
      clearEvent(addr readiness.available)
    result.registration = first
    result.tag = first.tag
  readiness.lock.release()

proc takeReady*(readiness: Readiness): ReadyEvent =
  ## No passive frame is needed when a producer already queued an event.
  while true:
    result = pop(readiness)
    let registration = result.registration
    if registration == nil: return
    if active(registration): return
    # A retired event must not address a reused engine slot.

proc nextReady*(readiness: Readiness; deadline: Deadline): ReadyEvent {.passive.} =
  while true:
    result = takeReady(readiness)
    if result.registration != nil: return
    if stopping() or monoNow() >= deadline: return
    discard wait(addr readiness.available, deadline)

proc join*(registration: Registration) {.passive.} =
  while not completed(registration):
    discard wait(addr registration.done, never)
    if not completed(registration): yieldNow()

proc discardReady*(readiness: Readiness) =
  ## Consumer only, after all registrations have completed.
  while pop(readiness).registration != nil: discard
