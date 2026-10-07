## Wake descriptors for the std backend's wait nodes: an eventfd on Linux,
## a sys/sock wake pair elsewhere (a pipe, or a loopback socket on Windows). A waiter parks on the read side with
## `submitPollAdd`, so whoever claims it wakes the waiter's own lane at once;
## std/threadpool itself wakes nobody when work is submitted. Leases are
## pooled; a descriptor returns to the pool drained.

import std/ticketlocks
import zal_net/private/sys/sock

when defined(linux):
  proc nnEventfdNb(): cint {.importc: "nn_eventfd_nb".}
    ## -1 before Linux 2.6.27 (or with NN_LINUX_COMPAT=1): a pipe then

const PoolMax = 256

type WakePool = object
  lock: TicketLock
  free: array[PoolMax, array[2, cint]]
  count: int
var pool: WakePool

proc takePair(pool: var WakePool; r, w: var cint): bool {.sync.} =
  result = false
  acquire(pool.lock)
  defer: release(pool.lock)
  {.cast(assumeSync).}:
    if pool.count > 0:
      dec pool.count
      r = pool.free[pool.count][0]
      w = pool.free[pool.count][1]
      result = true

proc putPair(pool: var WakePool; r, w: cint): bool {.sync.} =
  result = false
  acquire(pool.lock)
  defer: release(pool.lock)
  {.cast(assumeSync).}:
    if pool.count < PoolMax:
      pool.free[pool.count] = [r, w]
      inc pool.count
      result = true

proc drainPool(pool: var WakePool) {.sync.} =
  acquire(pool.lock)
  defer: release(pool.lock)
  {.cast(assumeSync).}:
    while pool.count > 0:
      dec pool.count
      wakeClose(pool.free[pool.count][0], pool.free[pool.count][1])

proc newPair(r, w: var cint): bool =
  when defined(linux):
    let fd = nnEventfdNb()
    if fd < 0: return wakePair(r, w)
    r = fd
    w = fd
    result = true
  else:
    result = wakePair(r, w)

proc leaseWake*(r, w: var cint): bool =
  if takePair(pool, r, w): return true
  result = newPair(r, w)

proc signalWake*(w: cint) =
  when defined(linux):
    var one = 1'u64
    discard sockWrite(w, addr one, 8)
  else:
    wakeSignal(w)

proc drainWake*(r: cint) =
  when defined(linux):
    var buf = default(array[64, byte])
    while sockRead(r, addr buf[0], buf.len) > 0: discard
  else:
    wakeDrain(r)

proc returnWake*(r, w: cint) =
  ## The caller drained `r` or never signalled it.
  if not putPair(pool, r, w): wakeClose(r, w)

proc closeWakePool*() =
  ## Called by the process runner after every waiter and pool worker is joined.
  drainPool(pool)
