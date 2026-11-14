# What a service shares between its accept loops, its connection handlers
# and `stop`: the listening sockets, a count of who is still inside, a token
# that ends every wait, and the event the last accept loop sets.
#
#   var life: ServiceLife
#   initLife(life)
#   life.listener = fd                    # a registered listening socket
#   # each accept loop: enterAcceptor, accept until AcceptClosed,
#   #   then `if leaveAcceptor(life): setEvent(addr life.done)`
#   # each connection: `if borrow(life, limit): ... unborrow(life)`
#   closeAdmission(life)                  # from `stop`: no new connections
#   discard waitQuiet(life, afterMs(5_000))
#
# A proxy has several accept loops on one listener, one per worker, and a
# handler per connection. Stopping it means three things in order: refuse
# new work, wake everything that waits, and wait until the last handler has
# left. This object is that order, written once for every protocol library.

import std/atomics
import zal_net/rt
import zal_net/rt/[cancel, sync, time]
import zal_net/raw/[io, socket, fdops]

type
  ServiceLife* = object
    initialized: bool
    listener*, udpListener*: cint
    starting: int             # 0 unused, 1 preparing, 2 started
    acceptors*: int           ## accept loops, until each has seen the close
    borrowers*: int           ## handshakes and control holds
    closing*: int
    stop*: CancelToken
    done*: Event

proc `=destroy`(life: var ServiceLife) =
  if life.initialized:
    if life.listener >= 0 and unregisterIdleListener(life.listener): closeFdRaw(life.listener)
    if life.udpListener >= 0: closeFdRaw(life.udpListener)
    release(life.stop)
    life.initialized = false

proc `=wasMoved`(life: var ServiceLife) {.nodestroy, inline.} =
  zeroMem(addr life, sizeof(life))

proc initLife*(life: var ServiceLife) =
  life.listener = -1
  life.udpListener = -1
  life.stop = newCancelToken()
  life.initialized = true

proc open*(life: var ServiceLife): bool {.inline.} =
  atomicLoad(life.closing, moAcquire) == 0

proc beginServe*(life: var ServiceLife): bool =
  var expected = 0
  if not atomicCompareExchange(life.starting, expected, 1, moAcquireRelease, moAcquire): return false
  if not open(life):
    atomicStore(life.starting, 2, moRelease)
    return false
  result = true

proc readyToAccept*(life: var ServiceLife) =
  atomicStore(life.starting, 2, moRelease)

proc borrow*(life: var ServiceLife; limit: int): bool =
  ## Reserve a place before a handler frame exists; none once closing.
  if not open(life): return false
  var count = atomicLoad(life.borrowers, moRelaxed)
  while count < limit:
    if atomicCompareExchange(life.borrowers, count, count + 1, moAcquireRelease, moRelaxed):
      if open(life): return true
      discard atomicFetchSub(life.borrowers, 1, moAcquireRelease)
      return false
  result = false

proc unborrow*(life: var ServiceLife) =
  discard atomicFetchSub(life.borrowers, 1, moAcquireRelease)

proc enterAcceptor*(life: var ServiceLife) =
  discard atomicFetchAdd(life.acceptors, 1, moAcquireRelease)

proc leaveAcceptor*(life: var ServiceLife): bool =
  ## True for the last one out.
  atomicFetchSub(life.acceptors, 1, moAcquireRelease) == 1

proc closeAdmission*(life: var ServiceLife) {.passive.} =
  ## Once: end the waits and retire the listener. Later calls wait for that.
  var expected = 0
  if atomicCompareExchange(life.closing, expected, 1, moAcquireRelease, moAcquire):
    cancel(life.stop)
    while atomicLoad(life.starting, moAcquire) == 1: sleepMs(1)
    let fd = life.listener
    if fd >= 0:
      discard closeListener(fd, acceptors = atomicLoad(life.acceptors, moAcquire), deadline = never)
      life.listener = -1
    if life.udpListener >= 0:
      closeFdRaw(life.udpListener)
      life.udpListener = -1
    atomicStore(life.closing, 2, moRelease)
  else:
    while atomicLoad(life.closing, moAcquire) != 2: sleepMs(1)

proc waitQuiet*(life: var ServiceLife; deadline: Deadline): bool {.passive.} =
  ## Until the accept loops and the borrowers are gone.
  if wait(addr life.done, deadline) != wrReady: return false
  while atomicLoad(life.borrowers, moAcquire) > 0:
    if expired(deadline): return false
    sleepMs(1)
  result = true
