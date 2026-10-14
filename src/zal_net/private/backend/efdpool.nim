## Wake descriptors for the std backend's wait nodes: an eventfd on Linux,
## a sys/sock wake pair elsewhere (a pipe, or a loopback socket on Windows). A waiter parks on the read side with
## `submitPollAdd`, so whoever claims it wakes the waiter's own lane at once;
## std/threadpool itself wakes nobody when work is submitted. Leases are
## pooled; a descriptor returns to the pool drained. Leased descriptors are
## recorded so runtime stop can wake every waiter once.

import std/atomics
import std/ticketlocks
import zal_net/private/sys/sock
import zal_net/private/core/parked

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

var leased: nil ptr UncheckedArray[int]   # read fd -> write fd + 1; < 0 while stop signals it
var leasedCap: int

proc initWakes*() {.sync.} =
  ## Once, before any lease.
  {.cast(assumeSync).}:
    if leased == nil: leased = newFdTable(leasedCap)

proc wakeTracked*(r: cint): bool {.sync.} =
  ## False for a descriptor the table cannot hold: its waiter keeps slicing.
  {.cast(assumeSync).}:
    result = leased != nil and r >= 0 and r < leasedCap

proc track(r, w: cint) {.sync.} =
  {.cast(assumeSync).}:
    let table = leased
    if table != nil and r >= 0 and r < leasedCap:
      atomicStore(table[r], int(w) + 1, moSequentiallyConsistent)

proc untrack(r: cint) {.sync.} =
  ## Waits out a stop signal in progress: the pair may be closed after this.
  {.cast(assumeSync).}:
    let table = leased
    if table == nil or r < 0 or r >= leasedCap: return
    while true:
      var cur = atomicLoad(table[r], moSequentiallyConsistent)
      if cur >= 0 and atomicCompareExchange(table[r], cur, 0, moSequentiallyConsistent): break
      cpuRelax()

proc leaseWake*(r, w: var cint): bool =
  result = takePair(pool, r, w) or newPair(r, w)
  if result: track(r, w)

proc signalWake*(w: cint) =
  when defined(linux):
    var one = 1'u64
    discard sockWrite(w, addr one, 8)
  else:
    wakeSignal(w)

proc wakeLeased*() {.sync.} =
  ## Runtime stop, once: a signal stays until drained, so a waiter that
  ## polls after this still wakes.
  {.cast(assumeSync).}:
    let table = leased
    if table == nil: return
    var r = 0
    while r < leasedCap:
      var cur = atomicLoad(table[r], moSequentiallyConsistent)
      if cur > 0 and atomicCompareExchange(table[r], cur, -cur, moSequentiallyConsistent):
        signalWake(cint(cur - 1))
        atomicStore(table[r], cur, moSequentiallyConsistent)
      r = r + 1

proc drainWake*(r: cint) =
  when defined(linux):
    var buf = default(array[64, byte])
    while sockRead(r, addr buf[0], buf.len) > 0: discard
  else:
    wakeDrain(r)

proc returnWake*(r, w: cint) =
  ## The caller drained `r` or never signalled it.
  untrack(r)
  if not putPair(pool, r, w): wakeClose(r, w)

proc closeWakePool*() =
  ## Called by the process runner after every waiter and pool worker is joined.
  drainPool(pool)
