  ## Both directions between `a` and `b` at once (the second in its own
  ## task) until both end. An end of stream is forwarded as a half-close; an
  ## error ends both. Idle means neither direction moved for `idleMs` (0: no
  ## limit). The caller still owns and closes both streams. Cancel with a
  ## token or `interrupt` on either stream; both pumps are drained first.
import zal_net/reader
export reader
import zal_net/streamconcepts
export streamconcepts
import zal_net/errors
export StreamEof, TooLong
## Byte streams in general: the `ByteStream` and `DuplexStream` concepts
## (TcpStream and UnixStream satisfy both), `copy` and `relay` between any
## two, and `BufReader` for lines, delimited heads or exact lengths. Generic
## procs are instantiated per stream type, with no vtable; between two
## sockets on Linux, `copy` and `relay` splice(2) through a pipe.
##
## ```nim
## # A TCP forwarder: whatever connects to :8080 is relayed to :80.
## proc forward(s: TcpStreamPtr): int {.passive.} =
##   var up = connect("example.com", 80)
##   if up.isOpen:
##     discard relay(s, addr up)
##     close(addr up)
##   result = 0
## ```

import zal_net/rt
import zal_net/raw/io
import zal_net/rt/sync
import zal_net/private/sys/posix
import zal_net/raw/fdops
import zal_net/raw/tcp
import zal_net/raw/unix
import zal_net/private/sys/sock
import zal_net/rt/cancel
import zal_net/private/core/iocancel

when defined(linux):
  {.compile: "../private/sys/nn_stream.c".}
  proc nnPipe(fds: ptr cint; size: cint): cint {.importc: "nn_pipe".}
  proc nnSplice(fdIn, fdOut: cint; len: clong): clong {.importc: "nn_splice".}
  proc nnSpliceOutput(fdIn, fdOut: cint; len: clong): clong {.importc: "nn_splice_output".}
  when defined(nnStreamFaultTest):
    {.passC: "-DNN_STREAM_FAULT_TEST".}


type
  CopyStats* = object
    bytes*: int64                 ## delivered to the destination
    error*: int                   ## 0: the source ended; else the failing result (IoTimedOut, -errno, -1)

  RelayStats* = object
    aToB*, bToA*: CopyStats

const
  CopyChunk = 64 * 1024
  PipeSize = 1024 * 1024
  CopyYieldBytes = 1024 * 1024    # bound monopolization by always-ready streams

# ------------------------------------------------------------------- copy

proc idleDeadline(act: ptr int64; idleMs: int): Deadline {.inline.} =
  if idleMs <= 0: never else: ioDeadline(act, idleMs)

proc stillActive(act: ptr int64; idleMs: int): bool {.inline.} =
  ## After a timeout: did the other direction move within the idle limit?
  idleMs > 0 and act != nil and monoNow() < ioDeadline(act, idleMs)

proc plainCopy[A: ByteStream; B: ByteStream](src: A; dst: B; act: ptr int64; idleMs: int;
                                           tokens: IoCancellation): CopyStats {.passive, untyped.} =
  result = CopyStats()
  var buf = default(array[CopyChunk, byte])
  var sinceYield = 0
  while true:
    if cancelled(tokens):
      result.error = ECancelled
      return
    var n = 0
    when A is TcpStreamPtr or A is UnixStreamPtr:
      fdRecvInline(nativeHandle(src), src.timeoutMs, addr buf[0], buf.len, idleDeadline(act, idleMs), n, tokens.operation, tokens.ownerStop, tokens.peerStop)
    else:
      when A is CancellableByteStream:
        n = recvInto(src, addr buf[0], buf.len, idleDeadline(act, idleMs), tokens.operation)
      else:
        n = recvInto(src, addr buf[0], buf.len, idleDeadline(act, idleMs))
    if n == 0: return
    if n < 0:
      if n == IoTimedOut and stillActive(act, idleMs): continue
      result.error = n
      return
    touchIo(act)
    var off = 0
    while off < n:
      var k = 0
      when B is TcpStreamPtr or B is UnixStreamPtr:
        fdSendInline(nativeHandle(dst), dst.timeoutMs, addr buf[off], n - off, idleDeadline(act, idleMs), k, tokens.operation, tokens.ownerStop, tokens.peerStop)
      else:
        when B is CancellableByteStream:
          k = sendFrom(dst, addr buf[off], n - off, idleDeadline(act, idleMs), tokens.operation)
        else:
          k = sendFrom(dst, addr buf[off], n - off, idleDeadline(act, idleMs))
      if k <= 0:
        if k == IoTimedOut and stillActive(act, idleMs): continue
        result.error = if k == 0: -1 else: k
        return
      off = off + k
      result.bytes = result.bytes + k
      touchIo(act)
      sinceYield = sinceYield + k
      if sinceYield >= CopyYieldBytes:
        sinceYield = 0
        yieldNow()

when defined(linux):
  const SpliceInvalidDescriptor = -22
  const SpliceUnavailable = -38

  proc drainSplicePipe(pr, dst: cint; remaining, dstMs: int;
                       act: ptr int64; idleMs: int;
                       tokens: IoCancellation): CopyStats {.passive.} =
    ## Cold fallback only: ingress already consumed these source bytes. Keep
    ## the pipe owned until every buffered byte is delivered or I/O fails.
    result = CopyStats()
    var buffer = default(array[CopyChunk, byte])
    var left = remaining
    while left > 0:
      if cancelled(tokens): return CopyStats(bytes: result.bytes, error: ECancelled)
      let n = readSome(pr, addr buffer[0], min(left, buffer.len))
      # No other reader owns this pipe, so recorded ingress is available.
      if n <= 0:
        result.error = if n == 0: -1 else: n
        return
      var offset = 0
      while offset < n:
        var sent = 0
        fdSendInline(dst, dstMs, addr buffer[offset], n - offset,
                     idleDeadline(act, idleMs), sent, tokens.operation, tokens.ownerStop, tokens.peerStop)
        if sent <= 0:
          if sent == IoTimedOut and stillActive(act, idleMs): continue
          result.error = if sent == 0: -1 else: sent
          return
        offset = offset + sent
        result.bytes = result.bytes + sent
        touchIo(act)
      left = left - n

  proc spliceCopy(src, dst: cint; srcMs, dstMs: int; act: ptr int64; idleMs: int;
                  pr, pw: cint; tokens: IoCancellation): CopyStats {.passive.} =
    ## Socket to socket through a pipe (read end `pr`, write end `pw`):
    ## the kernel moves the pages.
    result = CopyStats()
    var inPipe = 0
    var res = 0
    var sinceYield = 0
    while true:
      if cancelled(tokens):
        result.error = ECancelled
        return
      if inPipe == 0:
        let n = int(nnSplice(src, pw, clong(PipeSize)))
        if n == 0: return
        if n > 0:
          inPipe = n
          touchIo(act)
        else:
          let err = lastErr()
          if err != EAgain:
            result.error = -err
            return
          parkCancellable(src, {evRead}, limit(srcMs, idleDeadline(act, idleMs)), tokens, res)
          if res <= 0:
            if res == IoTimedOut and stillActive(act, idleMs): continue
            result.error = if res < 0: res else: -1
            return
          continue
      let k = int(nnSpliceOutput(pr, dst, clong(inPipe)))
      if k > 0:
        inPipe = inPipe - k
        result.bytes = result.bytes + k
        touchIo(act)
        sinceYield = sinceYield + k
        if sinceYield >= CopyYieldBytes:
          sinceYield = 0
          yieldNow()
      else:
        let err = if k == 0: 0 else: lastErr()
        if err != EAgain:
          result.error = if err == 0: -1 else: -err
          if result.error == SpliceInvalidDescriptor or result.error == SpliceUnavailable:
            let drained = drainSplicePipe(pr, dst, inPipe, dstMs, act, idleMs, tokens)
            result.bytes = result.bytes + drained.bytes
            if drained.error != 0: result.error = drained.error
          return
        parkCancellable(dst, {evWrite}, limit(dstMs, idleDeadline(act, idleMs)), tokens, res)
        if res <= 0:
          if res == IoTimedOut and stillActive(act, idleMs): continue
          result.error = if res < 0: res else: -1
          return


proc direction[A: ByteStream; B: ByteStream](src: A; dst: B; act: ptr int64; idleMs: int;
                                             splice: bool; tokens: IoCancellation): CopyStats {.passive, untyped.} =
  # No early return here: a statement then `return` in a `when` branch of
  # a generic passive proc crashes nimsem.
  when defined(linux) and (A is TcpStreamPtr or A is UnixStreamPtr) and (B is TcpStreamPtr or B is UnixStreamPtr):
    var p = default(array[2, cint])
    if splice and nnPipe(addr p[0], cint(PipeSize)) == 0:
      result = spliceCopy(nativeHandle(src), nativeHandle(dst), src.timeoutMs, dst.timeoutMs, act, idleMs, p[0], p[1], tokens)
      if result.error == SpliceInvalidDescriptor or result.error == SpliceUnavailable:
        # splice(2) refused these descriptors (EINVAL) or the kernel lacks
        # it (ENOSYS): copy through user space instead.
        let continued = plainCopy(src, dst, act, idleMs, tokens)
        result.bytes = result.bytes + continued.bytes
        result.error = continued.error
      discard sockClose(p[0])
      discard sockClose(p[1])
    else:
      result = plainCopy(src, dst, act, idleMs, tokens)
  else:
    result = plainCopy(src, dst, act, idleMs, tokens)

proc copy*[A: ByteStream; B: ByteStream](src: A; dst: B; idleMs = 0; splice = true;
                                       tok: nil CancelToken = nil; sourceStop: nil CancelToken = nil;
                                       destinationStop: nil CancelToken = nil): CopyStats {.passive.} =
  ## Everything from `src` to `dst` until `src` ends (`error` 0) or an
  ## operation fails. `idleMs` > 0 fails it after that long without
  ## progress; the streams' own idle limits apply too. Does not end
  ## `dst`: call `shutdownWrite` or `close` after. Native socket adapters may
  ## supply retained source/destination stop tokens to drain either owner.
  when not (A is CancellableByteStream and B is CancellableByteStream):
    if tok != nil: return CopyStats(error: NotSupported)
  when not ((A is TcpStreamPtr or A is UnixStreamPtr) and (B is TcpStreamPtr or B is UnixStreamPtr)):
    if sourceStop != nil or destinationStop != nil: return CopyStats(error: NotSupported)
  let tokens = ioCancellation(tok, sourceStop, destinationStop)
  retain(tokens)
  defer: release(tokens)
  var act = 0'i64
  touchIo(addr act)
  result = direction(src, dst, addr act, idleMs, splice, tokens)

# ------------------------------------------------------------------ relay

type
  RelayState = object
    act: int64                    # shared activity stamp: either direction's progress
    done: Event
    back: CopyStats

proc finishDir[A: DuplexStream; B: DuplexStream](src: A; dst: B; r: CopyStats) =
  if r.error == 0:
    shutdownWrite(dst)            # forward the half-close; the other way goes on
  else:
    interrupt(src)                # a failure ends both directions now
    interrupt(dst)

proc backward[A: DuplexStream; B: DuplexStream](a: A; b: B; st: ptr RelayState; idleMs: int;
                                                splice: bool; tok: nil CancelToken) {.passive.} =
  let tokens = ioCancellation(tok)
  let r = direction(b, a, addr st.act, idleMs, splice, tokens)
  finishDir(b, a, r)
  st.back = r
  setEvent(addr st.done)

proc relay*[A: DuplexStream; B: DuplexStream](a: A; b: B; idleMs = 60_000; splice = true;
                                           tok: nil CancelToken = nil): RelayStats {.passive.} =
  ## Both directions between `a` and `b` at once (the second in its own
  ## task) until both have ended. An end of stream is forwarded as a
  ## half-close; an error ends both directions. Idle means neither
  ## direction moved for `idleMs` (0: no limit beyond the streams' own,
  ## which a quiet direction outlives while the other one moves). The
  ## caller still owns and closes both streams. To stop a relay from
  ## outside, pass a token or `interrupt` either stream. Cancellation ends
  ## the compound relay and interrupts both sides, then drains both pumps.
  when not (A is CancellableByteStream and B is CancellableByteStream):
    if tok != nil:
      return RelayStats(aToB: CopyStats(error: NotSupported), bToA: CopyStats(error: NotSupported))
  retain(tok)
  defer: release(tok)
  let st = cast[ptr RelayState](alloc0(sizeof(RelayState)))
  if st == nil:
    return RelayStats(aToB: CopyStats(error: -12), bToA: CopyStats(error: -12))   # ENOMEM
  touchIo(addr st.act)
  if not trySpawnTask(backward(a, b, st, idleMs, splice, tok)):
    dealloc(st)
    result = RelayStats(aToB: CopyStats(error: ECancelled), bToA: CopyStats(error: ECancelled))
    return
  let tokens = ioCancellation(tok)
  let r = direction(a, b, addr st.act, idleMs, splice, tokens)
  finishDir(a, b, r)
  # Runtime cancellation can wake this wait before the sibling exits. Retain
  # both borrowed stream owners and shared state until its completion signal.
  while not isSet(addr st.done):
    discard wait(addr st.done, never)
    if not isSet(addr st.done): yieldNow()
  result = RelayStats(aToB: r, bToA: st.back)
  dealloc(st)
