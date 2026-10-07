## Non-blocking system calls and the passive I/O procs built on them.
## Results: >0 bytes, 0 EOF, negative OS error, IoAgain when the kernel
## would block. The regular procs are `noinline`: an installed Nimony
## optimizer bug can drop the assignment of their result at passive call
## sites.

import zal_net/errors
export IoAgain, AcceptAgain, AcceptBusy, AcceptClosed
import std/atomics
when defined(nnTraceRelay):
  import std/syncio
import zal_net/rt
import zal_net/private/sys/posix
import zal_net/private/sys/sock
import zal_net/net/sockaddr

const
  MSG_DONTWAIT* = when defined(macosx): 0x80.cint else: 0x40.cint
  MSG_WAITFORONE* = 0x10000.cint
  AcceptBurst* = 64 ## accepts per wake before an accept loop yields

const ENotSock = when defined(macosx): 38 else: 88

var gAcceptStop: int   # atomic: stopAccepting was called

proc acceptStopped*(): bool {.inline.} = atomicLoad(gAcceptStop, moAcquire) != 0
proc markAcceptStopped*() = atomicStore(gAcceptStop, 1, moRelease)

# Listener registry. The signal handler shuts every listener down, and
# `acceptNow` checks whether its listener is being closed. A slot's `key` is
# fd + 1 (0: free) so the handler can read it without a lock.
const MaxListeners* = 64

type ListenerSlot = object
  key: int       # atomic: fd + 1, or 0
  stopped: int   # atomic: closeListener runs
  owed: int      # atomic: acknowledgements closeListener still waits for

var gLsn: array[MaxListeners, ListenerSlot]
var gLsnStopped: int   # atomic: slots with `stopped` set

proc listenerSlot*(fd: cint): int =
  ## The registry slot of listener `fd`, or -1.
  result = -1
  var i = 0
  while i < MaxListeners:
    if atomicLoad(gLsn[i].key, moAcquire) == int(fd) + 1: return i
    i = i + 1

proc registerListener*(fd: cint): bool =
  ## Record a listener, for the stop signals and `closeListener`. False when
  ## all MaxListeners slots are taken.
  result = false
  if fd < 0: return
  var i = 0
  while i < MaxListeners:
    var free = 0
    if atomicCompareExchange(gLsn[i].key, free, int(fd) + 1, moAcquireRelease, moAcquire):
      return true
    i = i + 1

proc unregisterIdleListener*(fd: cint): bool =
  ## Retire a quiescent listener with no accept loops. A listener already
  ## closing must finish its acknowledgement protocol instead. Caller keeps
  ## the descriptor owned until this transition and the subsequent close.
  let slot = listenerSlot(fd)
  if slot < 0: return true
  if atomicLoad(gLsn[slot].stopped, moAcquire) != 0: return false
  atomicStore(gLsn[slot].key, 0, moRelease)
  result = true

proc listenerFd*(slot: int): cint {.inline.} =
  ## The fd in `slot`, or -1 when it is free. Async-signal-safe.
  cint(atomicLoad(gLsn[slot].key, moAcquire) - 1)

proc beginClose*(slot, owed: int) =
  ## Mark `slot` stopped, owing `owed` acknowledgements.
  atomicStore(gLsn[slot].owed, owed, moRelease)
  atomicStore(gLsn[slot].stopped, 1, moRelease)
  discard atomicFetchAdd(gLsnStopped, 1, moAcquireRelease)

proc ackClose*(slot: int) = discard atomicFetchSub(gLsn[slot].owed, 1, moAcquireRelease)
proc closeOwed*(slot: int): int {.inline.} = atomicLoad(gLsn[slot].owed, moAcquire)

proc freeListener*(slot: int) =
  atomicStore(gLsn[slot].stopped, 0, moRelease)
  discard atomicFetchSub(gLsnStopped, 1, moAcquireRelease)
  atomicStore(gLsn[slot].key, 0, moRelease)

proc closingSlot(fd: cint): int =
  ## The slot of `fd` when closeListener is closing it, else -1.
  result = -1
  if atomicLoad(gLsnStopped, moAcquire) == 0: return
  let i = listenerSlot(fd)
  if i >= 0 and atomicLoad(gLsn[i].stopped, moAcquire) != 0: result = i

proc listenerClosing*(fd: cint): bool {.inline.} =
  ## Ownership transfer is forbidden while serving-loop acknowledgements remain.
  closingSlot(fd) >= 0

proc closedResult(fd: cint): int =
  ## AcceptClosed, acknowledged once per accept loop when closeListener
  ## waits for it.
  let i = closingSlot(fd)
  if i >= 0: ackClose(i)
  result = AcceptClosed

when defined(linux):
  proc nnAcceptNb(fd: cint): cint {.importc: "nn_accept_nb".}
    ## accept4 with NONBLOCK|CLOEXEC, or accept + fcntl on kernels before 2.6.28

proc acceptNow*(listenFd: cint): int {.noinline.} =
  ## One non-blocking accept. >= 0 is a non-blocking descriptor; see
  ## AcceptAgain and AcceptBusy; other negative OS errors fail this attempt;
  ## AcceptClosed once `stopAccepting` or `closeListener` ran, or the
  ## listener is gone; the accept loop must then stop calling it.
  if closingSlot(listenFd) >= 0: return closedResult(listenFd)
  if acceptStopped(): return AcceptClosed
  while true:
    when defined(linux):
      let fd = nnAcceptNb(listenFd)
      if fd >= 0: return int(fd)
    else:
      let fd = sockAccept(listenFd, nil, nil)
      if fd >= 0:
        # BSD/Darwin accept inherits O_NONBLOCK from the non-blocking
        # listener; verify rather than assume (nn_win.c sets it).
        if makeNonblocking(fd): return int(fd)
        let error = lastErr()
        discard sockClose(fd)
        return -error
    let err = lastErr()
    if err == EIntr: continue
    if err == EAgain: return AcceptAgain
    if err == 24 or err == 23 or err == ENoBufs or err == 12: return AcceptBusy
    if err == 22 or err == 9 or err == ENotSock: return closedResult(listenFd)   # EINVAL, EBADF
    return -err

proc readSome*(fd: cint; buf: pointer; len: int): int {.noinline.} =
  while true:
    if len < 0: return InvalidInput
    if len == 0: return 0
    let n = sockRead(fd, buf, len)
    if n >= 0: return n
    let err = lastErr()
    if err == EIntr: continue
    if err == EAgain: return IoAgain
    return -err

proc writeSome*(fd: cint; buf: pointer; len: int): int {.noinline.} =
  ## Positive progress, zero for an empty write, IoAgain, or a negative error.
  while true:
    if len < 0: return InvalidInput
    if len == 0: return 0
    let n = sockWrite(fd, buf, len)
    if n > 0: return n
    if n == 0: return NoProgress
    let err = lastErr()
    if err == EIntr: continue
    if err == EAgain: return IoAgain
    return -err

proc readvSome*(fd: cint; iov: pointer; count: int): int {.noinline.} =
  ## readSome over an iovec array.
  if count < 0: return InvalidInput
  if count == 0: return 0
  while true:
    let n = sockReadv(fd, iov, cint(count))
    if n >= 0: return n
    let err = lastErr()
    if err == EIntr: continue
    if err == EAgain: return IoAgain
    return -err

proc writevSome*(fd: cint; iov: pointer; count: int): int {.noinline.} =
  ## writeSome over an iovec array.
  if count < 0: return InvalidInput
  if count == 0: return 0
  while true:
    let n = sockWritev(fd, iov, cint(count))
    if n > 0: return n
    if n == 0: return NoProgress
    let err = lastErr()
    if err == EIntr: continue
    if err == EAgain: return IoAgain
    return -err

proc sleepMs*(ms: int) {.passive.} =
  parkUntil(afterMs(ms))

proc yieldTask*() {.passive.} =
  yieldNow()

proc waitAccept*(listenFd: cint): int {.passive.} =
  ## Next accepted, non-blocking descriptor. Descriptor exhaustion backs
  ## off instead of spinning on a listener that stays readable.
  var res = 0
  while true:
    let fd = acceptNow(listenFd)
    if fd >= 0: return fd
    if fd == AcceptBusy:
      parkUntil(afterMs(50))
    elif fd == AcceptAgain:
      parkAccept(listenFd, res)
    elif fd == AcceptClosed:
      return -1
    else:
      # A rejected peer must not spin a continuously ready serving loop.
      parkUntil(afterMs(1))

proc waitRead*(fd: cint; buf: pointer; len: int; timeoutMs = 60_000;
               activity: nil ptr int64 = nil): int {.passive.} =
  ## One read of up to `len` bytes, parking until data, EOF or the deadline.
  ## Optional shared activity keeps one-way traffic alive. >0 bytes, 0 EOF,
  ## <0 failure or timeout.
  result = -1
  if len < 0: return InvalidInput
  if len == 0: return 0
  var res = 0
  while true:
    let n = readSome(fd, buf, len)
    if n >= 0:
      if n > 0: touchIo(activity)
      return n
    if n != IoAgain: return n
    parkReady(fd, {evRead}, activity, timeoutMs, res)
    if res <= 0: return (if res < 0: res else: -1)

proc waitWrite*(fd: cint; buf: pointer; len: int; timeoutMs = 60_000;
                activity: nil ptr int64 = nil): int {.passive.} =
  ## One write of up to `len` bytes, parking while the send buffer is full.
  result = -1
  if len < 0: return InvalidInput
  if len == 0: return 0
  var res = 0
  while true:
    let n = writeSome(fd, buf, len)
    if n > 0:
      touchIo(activity)
      return n
    if n != IoAgain: return n
    parkReady(fd, {evWrite}, activity, timeoutMs, res)
    if res <= 0: return (if res < 0: res else: -1)

proc connectError(fd: cint): int =
  var err: cint = 0
  var elen = cuint(sizeof(err))
  if sockGetsockopt(fd, SOL_SOCKET, SO_ERROR, addr err, addr elen) != 0:
    return -lastErr()
  when defined(nnTraceRelay):
    if err != 0:
      stderr.writeLine("connect failed fd " & $fd & " socket error " & $err)
  result = -int(err)

proc connectResult*(fd: cint): int =
  ## A started connect: 1 connected, negative OS failure (SO_ERROR read, and so
  ## cleared), 0 still under way. Asks the socket itself (a zero-time poll),
  ## not the wake: getpeername succeeds on Windows while a connect is pending.
  let error = connectError(fd)
  if error != 0: return error
  var p = PollFd(fd: fd, events: PollOut, revents: 0)
  let count = sockPoll(addr p, 1, 0)
  if count < 0: return -lastErr()
  if count == 0 or p.revents == 0: return 0
  let finalError = connectError(fd)
  result = if finalError != 0: finalError else: 1

template parkConnect*(fd: cint; deadline: Deadline; ok: var bool) =
  ## Park until a started connect finishes: `ok` when it connected. A wake
  ## that comes before the connect finished (a stale one: some parks resume
  ## by descriptor number) is waited through, a few times at most (a socket
  ## shut down while connecting would wake every time).
  block:
    ok = false
    var pcMask = 0
    var pcWakes = 0
    while pcWakes < 8:
      parkPoll(fd, {evWrite}, deadline, pcMask)
      if pcMask <= 0: break
      let pcState = connectResult(fd)
      if pcState != 0:
        ok = pcState > 0
        break
      pcWakes = pcWakes + 1

proc waitConnect*(fd: cint; timeoutMs = 10_000): int {.passive.} =
  ## Caller already started a non-blocking connect: 0 once it connected,
  ## -1 when it was refused or did not finish in time.
  var ok = false
  parkConnect(fd, afterMs(timeoutMs), ok)
  result = if ok: 0 else: -1

proc shutdownConn*(fd: cint) =
  if fd < 0: return
  closeFd(fd)

proc readAvail*(fd: cint; buf: pointer; len: int; timeoutMs = 60_000;
                activity: nil ptr int64 = nil): int {.passive.} =
  ## Pull what the kernel already has, and park only when the socket stays
  ## empty.
  result = waitRead(fd, buf, len, timeoutMs, activity)
  if result < 0: result = -1

proc writeAll*(fd: cint; buf: pointer; len: int; timeoutMs = 60_000;
               activity: nil ptr int64 = nil): bool {.passive.} =
  result = true
  var off = 0
  var res = 0
  while off < len:
    let n = writeSome(fd, cast[pointer](cast[int](buf) + off), len - off)
    if n > 0:
      touchIo(activity)
      off = off + n
    elif n == IoAgain:
      parkReady(fd, {evWrite}, activity, timeoutMs, res)
      if res <= 0: return false
    else:
      return false

proc writeCopy*(fd: cint; data: string): bool {.passive.} =
  ## The string lives in this frame for the duration of the call.
  result = true
  var bytes = data
  if bytes.len > 0:
    result = writeAll(fd, cast[pointer](bytes.toCString), bytes.len)

proc readExactUntil*(fd: cint; buf: pointer; len: int; deadline: Deadline): bool {.passive.} =
  ## Exactly `len` bytes, never more: bytes after them stay in the socket.
  ## Partial progress does not extend `deadline`.
  result = true
  var off = 0
  var res = 0
  while off < len:
    let p = cast[pointer](cast[int](buf) + off)
    let n = readSome(fd, p, len - off)
    if n > 0:
      off = off + n
    elif n == IoAgain:
      parkPoll(fd, {evRead}, deadline, res)
      if res <= 0: return false
    else:
      return false

proc readExact*(fd: cint; buf: pointer; len: int; timeoutMs = 60_000): bool {.passive.} =
  result = readExactUntil(fd, buf, len, afterMs(timeoutMs))
