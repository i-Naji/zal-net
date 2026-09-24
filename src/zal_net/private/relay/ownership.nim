## Included by relay/conn; block ownership, pools and connection closure.
# ------------------------------------------------------------------- pool

proc mapBlock(): nil Conn =
  result = cast[nil Conn](mapAnon(sizeof(ConnObj)))

proc unmapBlock(c: Conn) =
  unmapAnon(c, sizeof(ConnObj))

var poolLock: Lock
var poolHead: nil Conn
var poolLen: int
var poolClosing: bool
var liveConns: int      # connection blocks in use (atomic)
initLock(poolLock)

proc liveConnections*(): int =
  ## Connections currently holding a connection block.
  atomicLoad(liveConns, moRelaxed)

const PayloadPoolMax = 72
var payloadPool: array[PayloadPoolMax, nil BytesPtr]
var payloadPoolLen: int
var livePayloads: int
var payloadMaps: int

proc livePayloadBuffers*(): int = atomicLoad(livePayloads, moRelaxed)
proc payloadMappingCalls*(): int = atomicLoad(payloadMaps, moRelaxed)
proc hasPayload*(d: DirectionPtr): bool {.inline.} = d.payload != nil

proc retainedPayloadBuffers*(): int =
  acquire(poolLock)
  result = payloadPoolLen
  release(poolLock)

proc relayMetadataBytes*(): int = sizeof(ConnObj)

when defined(nnRelayFaultTest):
  var rejectPayload: bool
  proc failNextPayloadAllocation*() = atomicStore(rejectPayload, true, moRelease)

proc ensurePayload*(d: DirectionPtr): bool =
  ## Direction-affine; allocation failure leaves the direction unchanged.
  if d.payload != nil: return true
  when defined(nnRelayFaultTest):
    var expected = true
    if atomicCompareExchange(rejectPayload, expected, false, moAcquireRelease, moAcquire):
      return false
  acquire(poolLock)
  var memory: nil BytesPtr = nil
  if payloadPoolLen > 0:
    payloadPoolLen = payloadPoolLen - 1
    memory = payloadPool[payloadPoolLen]
    payloadPool[payloadPoolLen] = nil
  release(poolLock)
  if memory == nil:
    let mapped = mapAnon(BufCap)
    if mapped == nil: return false
    memory = bytesPtr(mapped)
    discard atomicFetchAdd(payloadMaps, 1, moRelaxed)
  d.payload = memory
  discard atomicFetchAdd(livePayloads, 1, moRelaxed)
  result = true

proc buf*(d: DirectionPtr): BytesPtr {.inline.} =
  ## Borrowed only while this direction holds a payload. Never retain its
  ## address outside a callback/batch; reclamation invalidates that borrow.
  let current = d.payload
  if current == nil: quit "relay payload is absent; call ensurePayload first"
  result = current

proc bufAt*(d: DirectionPtr; offset: int): BytesPtr {.inline.} =
  ## Caller supplies an in-range offset within its active window.
  when not defined(release):
    if offset < 0 or offset > BufCap: quit "relay buffer offset is out of range"
  result = buffers.offset(buf(d), offset)

proc releasePayload(d: DirectionPtr) =
  let current = d.payload
  d.payload = nil
  # Remove stale addresses before the buffer is visible to another owner.
  zeroMem(addr d.iov[0], sizeof(d.iov))
  if current != nil:
    acquire(poolLock)
    let keep = not poolClosing and payloadPoolLen < PayloadPoolMax
    if keep:
      payloadPool[payloadPoolLen] = current
      payloadPoolLen = payloadPoolLen + 1
    release(poolLock)
    if not keep: unmapAnon(current, BufCap)
    discard atomicFetchSub(livePayloads, 1, moRelaxed)

proc payloadEmpty(d: DirectionPtr): bool {.inline.} =
  d.off == d.fill and d.nspans == 0 and d.wOff == d.wEnd and
    d.iovAt == d.iovEnd and d.preAt == d.preLen

proc canReclaim(d: DirectionPtr): bool =
  if not payloadEmpty(d): return false
  let a = d.alt
  a == nil or payloadEmpty(a)

proc reclaimPayload(d: DirectionPtr) =
  # Called only by this direction's pump, outside callbacks and syscalls.
  releasePayload(d)
  let a = d.alt
  if a != nil: releasePayload(a)

proc initDir(d: DirectionPtr) =
  d.payload = nil
  d.src = -1
  d.dst = -1
  d.srcFramer = nil
  d.dstFramer = nil
  zeroMem(addr d.srcSt[0], sizeof(d.srcSt))
  zeroMem(addr d.dstSt[0], sizeof(d.dstSt))
  d.off = HeadRoom
  d.fill = HeadRoom
  d.nspans = 0
  d.bytes = 0
  d.wOff = 0
  d.wEnd = 0
  d.iovAt = 0
  d.iovEnd = 0
  d.preLen = 0
  d.preAt = 0
  d.relayout = false
  d.sinkInAlt = false
  d.alt = nil
  d.slotStride = 0
  d.slotMax = 0
  d.slotCount = 0
  d.inStride = 0

proc takeBlock(maxConns: int): nil Conn =
  ## A pooled block, else a fresh mapping; nil when mapping fails.
  acquire(poolLock)
  if poolClosing or (maxConns > 0 and atomicLoad(liveConns, moRelaxed) >= maxConns):
    release(poolLock)
    return nil
  # Reserve admission before mapping, so simultaneous accepts cannot exceed it.
  discard atomicFetchAdd(liveConns, 1, moRelaxed)
  let c = poolHead
  if c != nil:
    poolHead = c.poolNext
    poolLen = poolLen - 1
  release(poolLock)
  result = c
  if c == nil:
    result = mapBlock()
    if result == nil: discard atomicFetchSub(liveConns, 1, moRelease)

const AltPoolMax = 8                     # idle alt blocks kept for reuse
var altPool: nil DirectionPtr                 # linked through their `alt` field
var altPoolLen: int
var liveAlts: int                        # alt blocks in use (atomic)

proc liveAltBlocks*(): int =
  ## Alt blocks (relayout, splits) currently held by connections.
  atomicLoad(liveAlts, moRelaxed)

proc takeAlt(): nil DirectionPtr =
  acquire(poolLock)
  let a = altPool
  if a != nil:
    altPool = a.alt
    altPoolLen = altPoolLen - 1
  release(poolLock)
  result = a
  if result == nil: result = cast[nil DirectionPtr](mapAnon(sizeof(Dir)))
  if result != nil: discard atomicFetchAdd(liveAlts, 1, moRelaxed)

proc giveAlt(a: DirectionPtr) =
  zeroMem(addr a.dstSt[0], sizeof(a.dstSt))
  a.preLen = 0
  a.preAt = 0
  releasePayload(a)
  acquire(poolLock)
  let keep = not poolClosing and altPoolLen < AltPoolMax
  if keep:
    a.alt = altPool
    altPool = a
    altPoolLen = altPoolLen + 1
  release(poolLock)
  if not keep: unmapAnon(a, sizeof(Dir))
  discard atomicFetchSub(liveAlts, 1, moRelease)

proc newConn*(timeoutMs: int; maxConns = 0; payloadIdleMs = 30_000): nil Conn =
  ## A metadata block, or nil. Payloads are absent until first use.
  ## Reclaimed payloads remain in a separate bounded pool. Every byte is
  ## written before it is read. `proto`, `ext` and the framer states are
  ## zero; no hooks. maxConns limits live blocks atomically (0: unlimited).
  ## Nil also reports shutdown; the caller still owns its accepted socket.
  ## payloadIdleMs (default 30 seconds) reclaims empty directions independently
  ## of the connection timeout; nonpositive values disable idle reclamation.
  let c = takeBlock(maxConns)
  if c == nil: return nil
  c.refs = 0
  c.lastIo = 0
  c.timeoutMs = timeoutMs
  c.payloadIdleMs = max(0, payloadIdleMs)
  c.fd = -1
  c.up = -1
  c.poolNext = nil
  c.hooks = nil
  c.endReason = erEof
  c.upBytes = 0
  c.downBytes = 0
  c.failed = false
  zeroMem(addr c.proto[0], sizeof(c.proto))
  zeroMem(addr c.ext[0], sizeof(c.ext))
  initDir(addr c.a)
  initDir(addr c.b)
  touchIo(addr c.lastIo)
  result = c

proc closeFramers(d: DirectionPtr) =
  let s = d.srcFramer
  if s != nil: s.closeSource(d)
  let a = d.alt
  if d.sinkInAlt and a != nil:
    let k = a.dstFramer                  # the sink's state lives in the alt block
    if k != nil: k.closeSink(a)
  else:
    let k = d.dstFramer
    if k != nil: k.closeSink(d)
  if a != nil:
    giveAlt(a)
    d.alt = nil
  d.relayout = false
  d.sinkInAlt = false

proc freeConn*(c: Conn) =
  ## Framer close hooks, then back to the pool. Descriptors are the caller's.
  closeFramers(addr c.a)
  closeFramers(addr c.b)
  releasePayload(addr c.a)
  releasePayload(addr c.b)
  zeroMem(addr c.proto[0], sizeof(c.proto))
  zeroMem(addr c.ext[0], sizeof(c.ext))
  acquire(poolLock)
  let keep = not poolClosing and poolLen < PoolMax
  if keep:
    c.poolNext = poolHead
    poolHead = c
    poolLen = poolLen + 1
  release(poolLock)
  if not keep: unmapBlock(c)
  discard atomicFetchSub(liveConns, 1, moRelease)

proc stopRelayPool*(): bool =
  ## Control-thread only. Reject new blocks and release cached mappings.
  ## False while live connections retain blocks: they release them on exit;
  ## retry until true. Existing pumps can still allocate temporary buffers.
  ## Shutdown is final; the process pool cannot restart.
  acquire(poolLock)
  poolClosing = true
  while poolHead != nil:
    let c = poolHead
    if c == nil: break
    poolHead = c.poolNext
    unmapBlock(c)
  poolLen = 0
  while payloadPoolLen > 0:
    payloadPoolLen = payloadPoolLen - 1
    let memory = payloadPool[payloadPoolLen]
    payloadPool[payloadPoolLen] = nil
    if memory != nil: unmapAnon(memory, BufCap)
  while altPool != nil:
    let d = altPool
    if d == nil: break
    altPool = d.alt
    unmapAnon(d, sizeof(Dir))
  altPoolLen = 0
  result = atomicLoad(liveConns, moAcquire) == 0 and atomicLoad(liveAlts, moAcquire) == 0 and atomicLoad(livePayloads, moAcquire) == 0
  release(poolLock)

proc runEnd(c: Conn) {.inline.} =
  let h = c.hooks
  if h != nil:
    let e = h.onEnd
    if e != nil: e(c)

proc failConn*(c: Conn; why: string) =
  ## A handshake failure, before any pump runs: reset rather than FIN.
  when defined(nnTraceRelay): stderr.writeLine("fail " & $c.fd & " " & why)
  else: discard why
  c.endReason = erRejected
  runEnd(c)
  if c.fd >= 0: lingerRst(c.fd)
  if c.up >= 0: closeFd(c.up)
  freeConn(c)

proc closeConn*(c: Conn) =
  ## Before any pump runs, after a protocol reply: FIN, so the peer reads
  ## the reply.
  runEnd(c)
  if c.fd >= 0: closeFd(c.fd)
  if c.up >= 0: closeFd(c.up)
  freeConn(c)

const FailPollMs = 200   ## Windows, std backend: how often a parked pump looks for a failure

template relayPark(c: Conn; fd: cint; events: IoEvents; res: var int) =
  ## A pump's park (`parkReady` on the connection's idle stamp). On Windows
  ## with the std backend nothing wakes a parked task when the other
  ## direction fails (no shutdown hook there, no abort, and a FIN is not
  ## allowed): the park looks at `c.failed` every `FailPollMs` instead.
  when defined(windows):
    block:
      while true:
        parkPoll(fd, events, earlier(ioDeadline(addr c.lastIo, c.timeoutMs), afterMs(FailPollMs)), res)
        if res > 0: break
        if res == IoTimedOut:
          if atomicLoad(c.failed, moAcquire):
            res = ECancelled
            break
          if monoNow() >= ioDeadline(addr c.lastIo, c.timeoutMs): break
        elif not transientIo(res): break
  else:
    parkReady(fd, events, addr c.lastIo, c.timeoutMs, res)

template relayReadPark(c: Conn; d: DirectionPtr; res: var int) =
  ## Idle payload reclamation has its own deadline. It neither consumes input
  ## nor ends the connection. Descriptor readiness holds no buffer address.
  block:
    while true:
      let now = monoNow()
      let connectionDeadline = ioDeadline(addr c.lastIo, c.timeoutMs)
      var payloadDeadline = never
      let a = d.alt
      if c.payloadIdleMs > 0 and canReclaim(d) and
         (hasPayload(d) or (a != nil and hasPayload(a))):
        payloadDeadline = ioDeadline(addr c.lastIo, c.payloadIdleMs)
        if now >= payloadDeadline:
          reclaimPayload(d)
          payloadDeadline = never
      var deadline = earlier(connectionDeadline, payloadDeadline)
      when defined(windows):
        deadline = earlier(deadline, afterMs(FailPollMs))
      parkPoll(d.src, {evRead}, deadline, res)
      if res > 0: break
      if res == IoTimedOut:
        if atomicLoad(c.failed, moAcquire):
          res = ECancelled
          break
        # Either deadline may have moved while the other pump made progress.
        if monoNow() >= ioDeadline(addr c.lastIo, c.timeoutMs): break
      elif not transientIo(res): break

proc failStreams(c: Conn; d: DirectionPtr; reason: EndReason) =
  ## A direction failed: the connection fails, once. Neither peer may read
  ## a clean end of a stream cut short, the other direction's included
  ## (it stops here too): both sockets reset, and nothing else goes out (no
  ## FIN, no closing record). The other pump wakes: where the system can
  ## (Linux, macOS) the sockets are reset now, which wakes a pump parked
  ## either way; elsewhere a shutdown of the reading side wakes one parked
  ## on a read (Windows, loops backend: through the shutdown hook; std: the
  ## park looks for the failure, `relayPark`), and one parked on a write
  ## wakes on its peer's error, `relayPark`'s look or its idle timeout. Its
  ## end of stream then counts as this failure.
  var was = false
  if not atomicCompareExchange(c.failed, was, true, moAcquireRelease, moAcquire): return
  c.endReason = reason  # only the failure-claim winner writes this field
  for fd in [d.src, d.dst]:
    if not abortSocket(fd): shutdownRead(fd)

proc finishDir(c: Conn; d: DirectionPtr; graceful: bool; why = pfNone; code = 0) =
  ## Clean EOF propagates as a half-close (not after a failure). A failure
  ## fails the connection (`failStreams`); descriptors stay open until the
  ## other pump has finished. `why`/`code` say what ended a failed direction.
  when defined(nnTraceRelay):
    stderr.writeLine("finish " & $d.src & " -> " & $d.dst & " graceful " & $graceful &
                     " why " & $why & " code " & $code)
  if graceful:
    if not atomicLoad(c.failed, moAcquire): shutdownWrite(d.dst)
  else:
    let reason = if (why == pfReadWait or why == pfWriteWait) and code == IoTimedOut: erIdle else: erError
    failStreams(c, d, reason)
  if atomicFetchSub(c.refs, 1, moAcquireRelease) == 1:
    runEnd(c)
    closeFd(c.fd)
    closeFd(c.up)
    freeConn(c)

