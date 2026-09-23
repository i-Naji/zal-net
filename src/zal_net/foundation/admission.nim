## Worker-safe admission for retained resource owners.
## Keep one lease for a whole logical write, including every partial send.
## Closing stops admission; the enclosing owner interrupts I/O and drains leases
## before claiming cleanup. This module neither closes descriptors nor schedules.
import std/[ticketlocks, assertions]

when not defined(gcAtomicArc):
  {.error: "Worker-safe resource handles require --mm:atomicArc".}

type
  ResourcePhase* = enum
    resourceOpen, resourceClosing, resourceClosed
  OperationKind* = enum
    operationRead, operationWrite, operationTask
  AdmissionResult* = enum
    admissionAccepted, admissionBusy, admissionClosed
  ResourceGate* = ref object
    lock: TicketLock
    phase: ResourcePhase
    reading, writing, cleanupClaimed: bool
    tasks: int
  LeaseState = object
    gate: ResourceGate
    kind: OperationKind
    active: bool
  OperationLease* = ref LeaseState
    ## Copies retain the same admission. Releasing any alias releases it once.

proc finish(lease: var LeaseState) =
  let gate = lease.gate
  gate.lock.acquire()
  if lease.active:
    lease.active = false
    case lease.kind
    of operationRead: gate.reading = false
    of operationWrite: gate.writing = false
    of operationTask:
      assert gate.tasks > 0
      dec gate.tasks
  gate.lock.release()

proc `=destroy`(lease: var LeaseState) =
  finish(lease)
  `=destroy`(lease.gate)

proc newResourceGate*(): ResourceGate = ResourceGate(phase: resourceOpen)

proc admit*(gate: ResourceGate; kind: OperationKind;
            outcome: var AdmissionResult): nil OperationLease =
  ## The lease must remain retained until the operation has stopped borrowing.
  ## There is no lock held when this procedure returns.
  let lease = OperationLease(gate: gate, kind: kind)
  gate.lock.acquire()
  if gate.phase != resourceOpen:
    outcome = admissionClosed
  elif (kind == operationRead and gate.reading) or
       (kind == operationWrite and gate.writing):
    outcome = admissionBusy
  else:
    case kind
    of operationRead: gate.reading = true
    of operationWrite: gate.writing = true
    of operationTask: inc gate.tasks
    lease.active = true
    outcome = admissionAccepted
  gate.lock.release()
  if outcome == admissionAccepted: result = lease
  else: result = nil

proc release*(lease: OperationLease) = finish(lease[])

proc beginClosing*(gate: ResourceGate): bool =
  ## Exactly one caller starts interruption. Others may still wait for closed.
  gate.lock.acquire()
  result = gate.phase == resourceOpen
  if result: gate.phase = resourceClosing
  gate.lock.release()

proc claimCleanup*(gate: ResourceGate): bool =
  ## Exactly one cleanup owner, only after all I/O and child leases have drained.
  gate.lock.acquire()
  result = gate.phase == resourceClosing and not gate.cleanupClaimed and
           not gate.reading and not gate.writing and gate.tasks == 0
  if result: gate.cleanupClaimed = true
  gate.lock.release()

proc finishCleanup*(gate: ResourceGate) =
  ## Publish closed only after the enclosing owner has released native resources.
  gate.lock.acquire()
  assert gate.phase == resourceClosing and gate.cleanupClaimed
  gate.phase = resourceClosed
  gate.lock.release()

proc phase*(gate: ResourceGate): ResourcePhase =
  gate.lock.acquire()
  result = gate.phase
  gate.lock.release()
