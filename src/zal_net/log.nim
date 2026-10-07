{.feature: "assumeSync".}
# Shared state uses pool/lifecycle locks, atomics and publication barriers.
import zal_net/private/runtime
## Asynchronous logging that never blocks a loop. Each loop (or pool worker)
## appends fixed-size records to its own ring; other threads share one ring.
## A logger thread formats them and writes each batch with one write(2).
## When a ring is full the record is dropped and counted, and the logger
## reports the count. Messages longer than 240 bytes are truncated.
##
## Use the `logDebug`/`logInfo`/`logWarn`/`logError` templates: they build
## the message only when the level is enabled.

import std/atomics
import std/ticketlocks
import zal_net/rt
import zal_net/private/services
import zal_net/private/core/eventcount
import zal_net/private/sys/threads
import zal_net/private/sys/sock
when not defined(windows): import zal_net/private/sys/posix
import zal_net/private/sharedmem
import zal_net/buffers

type
  LogLevel* = enum
    lvDebug, lvInfo, lvWarn, lvError, lvOff

const
  TextMax = 240

type
  LogRec = object
    mono: int64
    shard: int32
    lv: uint8
    len: uint16
    text: array[TextMax, char]

  Ring = object
    lock: TicketLock
    head, count: int
    dropped: int
    recs: ptr UncheckedArray[LogRec]


const
  LoggerUnused = 0
  LoggerRunning = 1
  LoggerClosing = 2
  LoggerJoined = 3

var gUp: int                 # atomic, one process lifetime
var gLifecycle: TicketLock  # init/stop/join only; never held by a producer
var gProducers: int          # atomic, retains rings and wake during publication
var gStopped: int            # atomic, worker has stopped touching shared storage
var gWorker: ThreadHandle
var gLevel: int = ord(lvInfo) # atomic
var gFd: cint = 2
var gShards: int
var gSlots: int
var gRings: unchecked ptr UncheckedArray[Ring]   # set with gShards, before gUp: non-nil when gShards > 0
var gPending: int            # atomic: records not yet written
var gWake = newEventCount()
var gWallOffset: int64       # realtime - monotonic, ns

proc logEnabled*(lv: LogLevel): bool {.inline.} =
  result = atomicLoad(gUp, moAcquire) == LoggerRunning and ord(lv) >= atomicLoad(gLevel, moRelaxed)

proc setLogLevel*(lv: LogLevel) = atomicStore(gLevel, ord(lv), moRelaxed)

proc logMsg*(lv: LogLevel; msg: openArray[char]) =
  ## Append one record; never blocks beyond the ring's lock.
  # Increment before checking state. Sequential consistency pairs with stop:
  # a producer that observed Running must be counted before storage is freed.
  discard atomicFetchAdd(gProducers, 1, moSequentiallyConsistent)
  if atomicLoad(gUp, moSequentiallyConsistent) != LoggerRunning or
      ord(lv) < atomicLoad(gLevel, moRelaxed):
    discard atomicFetchSub(gProducers, 1, moSequentiallyConsistent)
    return
  var sh = beShardId()
  if sh >= gShards: sh = gShards - 1
  let r = addr gRings[sh]
  let n = min(msg.len, TextMax)
  acquire(r.lock)
  if r.count == gSlots:
    r.dropped = r.dropped + 1
    release(r.lock)
    discard atomicFetchSub(gProducers, 1, moSequentiallyConsistent)
    return
  let rec = addr r.recs[(r.head + r.count) mod gSlots]
  rec.mono = int64(monoNow())
  rec.shard = int32(sh)
  rec.lv = uint8(ord(lv))
  rec.len = uint16(n)
  if n > 0: copyMem(addr rec.text[0], unsafeAddr msg[0], n)
  r.count = r.count + 1
  # Count before publishing the ring entry to the consumer.
  let pending = atomicFetchAdd(gPending, 1, moRelease) + 1
  release(r.lock)
  if lv >= lvError or pending == gSlots div 2: notifyOne(gWake)
  discard atomicFetchSub(gProducers, 1, moSequentiallyConsistent)

proc logMsg*(lv: LogLevel; msg: string) =
  if msg.len > 0: logMsg(lv, msg.toOpenArray(0, msg.len - 1))

template logDebug*(msg: untyped) =
  if logEnabled(lvDebug): logMsg(lvDebug, msg)
template logInfo*(msg: untyped) =
  if logEnabled(lvInfo): logMsg(lvInfo, msg)
template logWarn*(msg: untyped) =
  if logEnabled(lvWarn): logMsg(lvWarn, msg)
template logError*(msg: untyped) =
  if logEnabled(lvError): logMsg(lvError, msg)

# ------------------------------------------------------------ logger thread

type Line = object
  buf: array[512, char]
  len: int

proc put(l: var Line; c: char) {.inline.} =
  if l.len < l.buf.len:
    l.buf[l.len] = c
    l.len = l.len + 1

proc putNum(l: var Line; v: int64; width: int) =
  var digits = default(array[20, char])
  var n = v
  var k = 0
  while k < width or n > 0:
    digits[k] = char(ord('0') + int(n mod 10))
    n = n div 10
    k = k + 1
  while k > 0:
    k = k - 1
    put(l, digits[k])

proc putStr(l: var Line; s: string) =
  for c in s: put(l, c)

proc civil(days: int64; y, m, d: var int64) =
  ## Days since 1970-01-01 to a UTC calendar date (Howard Hinnant's method).
  let z = days + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  d = doy - (153 * mp + 2) div 5 + 1
  m = (if mp < 10: mp + 3 else: mp - 9)
  y = yoe + era * 400 + (if m <= 2: 1 else: 0)

proc format(l: var Line; rec: ptr LogRec) =
  l.len = 0
  let wall = rec.mono + gWallOffset
  let secs = wall div 1_000_000_000
  let ms = (wall mod 1_000_000_000) div 1_000_000
  var y = 0'i64
  var mo = 0'i64
  var d = 0'i64
  civil(secs div 86400, y, mo, d)
  let sod = secs mod 86400
  putNum(l, y, 4); put(l, '-'); putNum(l, mo, 2); put(l, '-'); putNum(l, d, 2); put(l, 'T')
  putNum(l, sod div 3600, 2); put(l, ':'); putNum(l, (sod mod 3600) div 60, 2); put(l, ':')
  putNum(l, sod mod 60, 2); put(l, '.'); putNum(l, ms, 3); putStr(l, "Z ")
  case LogLevel(rec.lv)
  of lvDebug: putStr(l, "DEBUG ")
  of lvInfo: putStr(l, "INFO ")
  of lvWarn: putStr(l, "WARN ")
  of lvError: putStr(l, "ERROR ")
  of lvOff: discard
  var i = 0
  while i < int(rec.len):
    put(l, rec.text[i])
    i = i + 1
  put(l, '\n')

proc writeAllFd(p: pointer; n: int) =
  var off = 0
  while off < n:
    let w = fileWrite(gFd, offset(bytesPtr(p), off), n - off)
    when not defined(windows):
      if w < 0 and lastErr() == EIntr: continue
    if w <= 0: return
    off = off + w

proc drainOnce() =
  var obuf = default(array[16384, char])
  var outLen = 0
  var line = default(Line)
  var rec = default(LogRec)
  var sh = 0
  var total = 0
  while sh < gShards:
    let r = addr gRings[sh]
    while true:
      acquire(r.lock)
      if r.count == 0:
        let dropped = r.dropped
        r.dropped = 0
        release(r.lock)
        if dropped > 0:
          rec.mono = int64(monoNow())
          rec.lv = uint8(ord(lvWarn))
          var msg = "log: dropped " & $dropped & " records"
          rec.len = uint16(min(msg.len, TextMax))
          copyMem(addr rec.text[0], cast[pointer](msg.toCString), int(rec.len))
          format(line, addr rec)
          if outLen + line.len > obuf.len:
            writeAllFd(addr obuf[0], outLen)
            outLen = 0
          copyMem(addr obuf[outLen], addr line.buf[0], line.len)
          outLen = outLen + line.len
        break
      rec = r.recs[r.head]
      r.head = (r.head + 1) mod gSlots
      r.count = r.count - 1
      release(r.lock)
      total = total + 1
      format(line, addr rec)
      if outLen + line.len > obuf.len:
        writeAllFd(addr obuf[0], outLen)
        outLen = 0
      copyMem(addr obuf[outLen], addr line.buf[0], line.len)
      outLen = outLen + line.len
    sh = sh + 1
  if outLen > 0: writeAllFd(addr obuf[0], outLen)
  if total > 0: discard atomicFetchSub(gPending, total, moAcquireRelease)

proc loggerMain(arg: nil pointer) {.nimcall.} =
  while true:
    let t = prepareWait(gWake)
    let closing = atomicLoad(gUp, moSequentiallyConsistent) == LoggerClosing
    if not closing and atomicLoad(gPending, moAcquire) == 0:
      commitWait(gWake, t, 100)
    else:
      cancelWait(gWake)
    if closing and atomicLoad(gProducers, moSequentiallyConsistent) == 0:
      # All admitted publications are finished, including dropped-record counts.
      drainOnce()
      atomicStore(gStopped, 1, moRelease)
      return
    drainOnce()

proc releaseRings() =
  var i = 0
  while i < gShards:
    freeShared(gRings[i].recs)
    i = i + 1
  if gShards > 0: freeShared(gRings)
  gShards = 0

proc stopLogger*()
proc joinLogger*(): bool

proc initLogger*(fd: cint = 2; level = lvInfo; ringSlots = 1024): bool =
  ## Borrow `fd` until joinLogger succeeds. Call after initRuntime. Repeated
  ## initialization while running succeeds; shutdown is final (no restart).
  acquire(gLifecycle)
  let state = atomicLoad(gUp, moSequentiallyConsistent)
  if state != LoggerUnused:
    release(gLifecycle)
    return state == LoggerRunning
  gFd = fd
  gShards = max(1, beShardCount())
  gSlots = max(16, ringSlots)
  gRings = cast[ptr UncheckedArray[Ring]](requireShared(gShards * sizeof(Ring)))
  var i = 0
  while i < gShards:
    gRings[i].recs = cast[ptr UncheckedArray[LogRec]](requireShared(gSlots * sizeof(LogRec)))
    i = i + 1
  gWallOffset = realtimeNs() - int64(monoNow())
  atomicStore(gLevel, ord(level), moRelaxed)
  if not startJoinable(gWorker, loggerMain, nil):
    releaseRings()
    freeEventCount(gWake)
    atomicStore(gStopped, 1, moRelease)
    atomicStore(gUp, LoggerJoined, moSequentiallyConsistent)
    release(gLifecycle)
    return false
  atomicStore(gUp, LoggerRunning, moSequentiallyConsistent)
  release(gLifecycle)
  result = true

proc stopLogger*() =
  ## Reject new records and drain accepted ones. Nonblocking. A blocked write
  ## retains its worker, rings and wake; the borrowed descriptor stays open.
  acquire(gLifecycle)
  let state = atomicLoad(gUp, moSequentiallyConsistent)
  if state == LoggerUnused:
    freeEventCount(gWake)
    atomicStore(gStopped, 1, moRelease)
    atomicStore(gUp, LoggerJoined, moSequentiallyConsistent)
  elif state == LoggerRunning:
    atomicStore(gUp, LoggerClosing, moSequentiallyConsistent)
    notifyOne(gWake)
  release(gLifecycle)

proc loggerStopped*(): bool =
  result = atomicLoad(gStopped, moAcquire) != 0

proc joinLogger*(): bool =
  ## Control-thread only. False while draining or blocked in an OS write.
  ## Retry after making the sink writable. Never force-free reachable storage.
  acquire(gLifecycle)
  if atomicLoad(gUp, moSequentiallyConsistent) == LoggerJoined:
    release(gLifecycle)
    return true
  if not loggerStopped() or not joinThread(gWorker):
    release(gLifecycle)
    return false
  releaseRings()
  freeEventCount(gWake)
  atomicStore(gUp, LoggerJoined, moSequentiallyConsistent)
  release(gLifecycle)
  result = true

proc flushLogger*(timeoutMs = 1000) =
  ## Wait for accepted records, bounded by timeoutMs. This blocks the calling
  ## thread, so use outside event-loop tasks. It does not shut down the logger.
  acquire(gLifecycle)
  let state = atomicLoad(gUp, moSequentiallyConsistent)
  if state == LoggerRunning or state == LoggerClosing: notifyOne(gWake)
  release(gLifecycle)
  var waited = 0
  while atomicLoad(gPending, moAcquire) > 0 and waited < timeoutMs:
    sleepUs(1000)
    waited = waited + 1

if not registerProcessService(stopLogger, joinLogger):
  freeEventCount(gWake)
  atomicStore(gStopped, 1, moRelease)
  atomicStore(gUp, LoggerJoined, moRelease)
