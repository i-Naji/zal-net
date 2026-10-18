## Included by relay/conn; flat passive pumps and batched I/O.
# ---------------------------------------------------------- framed source

proc overlapMove(dst, src: pointer; n: csize_t): pointer {.importc: "memmove", header: "<string.h>".}

proc readRoom(d: DirectionPtr): int =
  ## Space for the next read. Move an incomplete record back to HeadRoom
  ## only when the tail is too short for a maximal one.
  if d.off >= d.fill:
    d.off = HeadRoom
    d.fill = HeadRoom
  elif BufCap - d.fill < d.inStride + HeadRoom and d.off > HeadRoom:
    let n = d.fill - d.off
    discard overlapMove(bufAt(d, HeadRoom), bufAt(d, d.off), csize_t(n))
    d.off = HeadRoom
    d.fill = HeadRoom + n
  result = BufCap - d.fill

proc ingestFramed(c: Conn; d: DirectionPtr; f: Framer; short: var bool): int {.noinline.} =
  ## Decode what is buffered (`f` is d.srcFramer); read more until a batch
  ## is ready. `short` says whether the last read left room.
  let ended = f.sourceEnded
  if ended != nil and ended(d): return InEof
  if not hasPayload(d):
    let ready = peekInput(d.src)
    if ready == IoAgain: return InAgain
    if ready == 0:
      return (if d.off == d.fill and f.atBoundary(d): InEof else: InFail)
    # Allocate for hard errors too: readFailed may consume a kTLS control record.
    if not ensurePayload(d): return InFail
  while true:
    let k = f.open(c, d)
    if k != 0: return k
    let room = readRoom(d)
    let n = readSome(d.src, bufAt(d, d.fill), room)
    if n > 0:
      touchIo(addr c.lastIo)
      d.fill = d.fill + n
      short = n < room
    elif n == IoAgain:
      return InAgain
    elif n == 0:
      if d.off == d.fill and f.atBoundary(d): return InEof
      return InFail
    else:
      let err = lastErr()                        # before anything else can change it
      let rf = f.readFailed
      if rf == nil: return InFail
      let k = rf(c, d, err)
      if k != InAgain: return k

proc drainedFramed(d: DirectionPtr; f: Framer): bool =
  ## Nothing buffered, no record half open, no end seen: only the socket
  ## can bring more.
  if d.off < d.fill or not f.atBoundary(d): return false
  let ended = f.sourceEnded
  result = ended == nil or not ended(d)

# ----------------------------------------------------------- plain source

proc recvSome(fd: cint; buf: pointer; len: int): int =
  ## recv(2), not read(2): no file-position lock on the way to the socket.
  while true:
    let n = sockRecv(fd, buf, csize_t(len), 0)
    if n >= 0: return n
    let err = lastErr()
    if err == EIntr: continue
    if err == EAgain: return IoAgain
    return -err

proc sendSome(fd: cint; buf: pointer; len: int): int =
  while true:
    let n = sockSend(fd, buf, csize_t(len), 0)
    if n > 0: return n
    if n == 0: return -1
    let err = lastErr()
    if err == EIntr: continue
    if err == EAgain: return IoAgain
    return -err

proc plainSpans(d: DirectionPtr; total: int) =
  var left = total
  var i = 0
  while left > 0:
    let n = min(left, d.slotMax)
    d.spans[i] = Span(off: slotOff(d, i), len: n)
    left = left - n
    i = i + 1
  d.nspans = i
  d.bytes = total

proc ingestPlain(c: Conn; d: DirectionPtr): int {.noinline.} =
  ## readv scatters plaintext into record slots, leaving the sink's head
  ## and tail gaps, so a full batch is framed in place and written at once.
  if not hasPayload(d):
    let ready = peekInput(d.src)
    if ready == IoAgain: return InAgain
    if ready == 0: return InEof
    if ready < 0: return InFail
    if not ensurePayload(d): return InFail
  var n = 0
  if d.slotStride == d.slotMax:
    # No gaps between the slots: one plain read.
    n = recvSome(d.src, bufAt(d, slotOff(d, 0)), d.slotCount * d.slotMax)
  else:
    var i = 0
    while i < d.slotCount:
      d.iov[i].iov_base = bufAt(d, slotOff(d, i))
      d.iov[i].iov_len = csize_t(d.slotMax)
      i = i + 1
    n = readvSome(d.src, addr d.iov[0], d.slotCount)
  if n > 0:
    touchIo(addr c.lastIo)
    plainSpans(d, n)
    return d.nspans
  if n == 0: return InEof
  if n == IoAgain: return InAgain
  result = InFail

# ------------------------------------------------------------------- sink

proc prepareEmit(c: Conn; d: DirectionPtr): bool {.noinline.} =
  let f = d.dstFramer
  if f != nil: return f.seal(c, d)
  var i = 0
  while i < d.nspans:
    d.iov[i].iov_base = bufAt(d, d.spans[i].off)
    d.iov[i].iov_len = csize_t(d.spans[i].len)
    i = i + 1
  d.iovAt = 0
  d.iovEnd = d.nspans
  result = true

proc advanceWritten(d: DirectionPtr; written: int) =
  if d.dstFramer != nil:
    d.wOff = d.wOff + written
    return
  var left = written
  while left > 0 and d.iovAt < d.iovEnd:
    let l = int(d.iov[d.iovAt].iov_len)
    if left >= l:
      left = left - l
      d.iovAt = d.iovAt + 1
    else:
      d.iov[d.iovAt].iov_base = offsetOrNil(d.iov[d.iovAt].iov_base, left)
      d.iov[d.iovAt].iov_len = csize_t(l - left)
      left = 0

proc emitSome(c: Conn; d: DirectionPtr): int {.noinline.} =
  ## 1: batch written; InAgain: park until writable; InFail: error.
  let sf = d.dstFramer
  if sf != nil:
    if d.preAt < d.preLen:
      let wp = sf.writePrefix
      if wp != nil:
        let k = wp(c, d)
        if k == InAgain: return InAgain
        if k < 0: return InFail
        d.preLen = 0
        d.preAt = 0
    while d.preAt < d.preLen:
      # The sink's control prefix, then its region, in one writev.
      d.iov[0].iov_base = addr d.pre[d.preAt]
      d.iov[0].iov_len = csize_t(d.preLen - d.preAt)
      var cnt = 1
      if d.wOff < d.wEnd:
        d.iov[1].iov_base = bufAt(d, d.wOff)
        d.iov[1].iov_len = csize_t(d.wEnd - d.wOff)
        cnt = 2
      let n = writevSome(d.dst, addr d.iov[0], cnt)
      if n > 0:
        touchIo(addr c.lastIo)
        let p = min(n, d.preLen - d.preAt)
        d.preAt = d.preAt + p
        d.wOff = d.wOff + (n - p)
      elif n == IoAgain:
        return InAgain
      else:
        when defined(nnTraceRelay):
          stderr.writeLine("prefix write failed fd " & $d.dst & " result " & $n &
                           " prefix " & $(d.preLen - d.preAt) & " payload " & $(d.wEnd - d.wOff))
        return InFail
    d.preLen = 0
    d.preAt = 0
    while d.wOff < d.wEnd:
      let n = writeSome(d.dst, bufAt(d, d.wOff), d.wEnd - d.wOff)
      if n > 0:
        touchIo(addr c.lastIo)
        d.wOff = d.wOff + n
      elif n == IoAgain:
        return InAgain
      else:
        when defined(nnTraceRelay):
          stderr.writeLine("record write failed fd " & $d.dst & " result " & $n &
                           " bytes " & $(d.wEnd - d.wOff))
        return InFail
  else:
    while d.iovAt < d.iovEnd:
      var n = 0
      let base = d.iov[d.iovAt].iov_base
      if d.iovEnd - d.iovAt == 1 and base != nil:
        n = sendSome(d.dst, base, int(d.iov[d.iovAt].iov_len))
      else:
        n = writevSome(d.dst, addr d.iov[d.iovAt], d.iovEnd - d.iovAt)
      if n > 0:
        touchIo(addr c.lastIo)
        advanceWritten(d, n)
      elif n == IoAgain:
        return InAgain
      else:
        return InFail
  result = 1

# ----------------------------------------------------------------- splice

when defined(linux):
  const
    SpliceInvalid = 22                   # EINVAL: these descriptors cannot splice
    SpliceMissing = 38                   # ENOSYS
    SplicePipe = 1 shl 20                # pipe size asked for, and bytes per splice

  proc spliceable(c: Conn; d: DirectionPtr): bool {.inline.} =
    ## Plain to plain, and no hook that looks at the batches.
    if d.srcFramer != nil or d.dstFramer != nil: return false
    let h = c.hooks
    result = h == nil or h.onBatch == nil

  proc pipeToSlots(d: DirectionPtr; pr: cint; held: var int): int =
    ## What a refused splice left in the pipe, a slots' worth at a time, as
    ## a batch: its span count, or InFail.
    if not ensurePayload(d): return InFail
    let want = min(held, d.slotCount * d.slotMax)
    var got = 0
    while got < want:
      let n = readSome(pr, bufAt(d, slotOff(d, 0) + got), want - got)
      if n <= 0: return InFail
      got = got + n
    held = held - got
    plainSpans(d, got)
    result = d.nspans

  proc closePipe(pr, pw: var cint) =
    if pr >= 0: discard sockClose(pr)
    if pw >= 0: discard sockClose(pw)
    pr = -1
    pw = -1

  template spliceDirection(c: Conn; d: DirectionPtr; pr, pw: cint; moved: ptr int64;
                           held, sent, res: var int; graceful: var bool; why: var PumpFailure;
                           code: var int; done: var bool) =
    ## Socket to socket through the pipe until the source ends or something
    ## fails (`done`). A refused splice leaves `done` false, and `held`
    ## bytes in the pipe: the direction goes on through user space. A short
    ## splice parks first rather than asking again for an EAGAIN.
    block splicing:
      var drainedIn = false
      var fullOut = false
      while true:
        if held == 0:
          if drainedIn:
            drainedIn = false
          else:
            let n = int(nnSplice(d.src, pw, clong(SplicePipe)))
            if n > 0:
              held = n
              drainedIn = n < SplicePipe
              touchIo(addr c.lastIo)
              continue
            if n == 0:
              done = true
              if atomicLoad(c.failed, moAcquire): why = pfPeer
              else: graceful = true
              break splicing
            let err = lastErr()
            if err == SpliceInvalid or err == SpliceMissing: break splicing
            if err != EAgain:
              done = true
              why = pfSource
              code = -err
              break splicing
          sent = 0
          relayReadPark(c, d, res)
          if res <= 0:
            done = true
            why = pfReadWait
            code = res
            break splicing
          continue
        if not fullOut:
          let k = int(nnSpliceOutput(pr, d.dst, clong(held)))
          if k > 0:
            held = held - k
            fullOut = held > 0
            touchIo(addr c.lastIo)
            atomicStore(moved[], moved[] + k, moRelaxed)
            sent = sent + k
            if sent >= YieldBytes:
              sent = 0
              yieldNow()
            continue
          let err = if k == 0: 0 else: lastErr()
          if err == SpliceInvalid or err == SpliceMissing: break splicing
          if err != EAgain:
            done = true
            why = pfSink
            code = if err == 0: -1 else: -err
            break splicing
        fullOut = false
        sent = 0
        relayPark(c, d.dst, {evWrite}, res)
        if res <= 0:
          done = true
          why = pfWriteWait
          code = res
          break splicing

# ------------------------------------------------------------------- pump

proc pump*(c: Conn; d: DirectionPtr) {.passive.} =
  ## One direction, start to finish, in a single passive frame. A batch
  ## already in d.spans (initial payload from a handshake) goes out first.
  var res = 0
  var sent = 0
  var graceful = false
  var first = true
  var why = pfNone
  var code = 0    # result from the failed operation
  var drained = false   # the source's last read came up short: park first
  var short = false
  var spliceNext = false   # a read filled a whole slot: bulk, splice from here
  var spliceOff = false
  var pr: cint = -1        # the splice pipe, and what it holds
  var pw: cint = -1
  var held = 0
  let moved = if d == addr c.a: addr c.upBytes else: addr c.downBytes
  block run:
    while true:
      when defined(linux):
        if spliceNext and d.nspans == 0:
          spliceNext = false
          var p = default(array[2, cint])
          if nnPipe(addr p[0], cint(SplicePipe)) == 0:
            pr = p[0]
            pw = p[1]
            var done = false
            spliceDirection(c, d, pr, pw, moved, held, sent, res, graceful, why, code, done)
            if done: break run
            if held == 0: closePipe(pr, pw)
          spliceOff = true                     # refused (or no pipe): user space from here
      if d.nspans == 0:
        while true:
          let f = d.srcFramer
          var k = InAgain
          when defined(linux):
            if held > 0:
              k = pipeToSlots(d, pr, held)     # what a refused splice left, first
              if held == 0: closePipe(pr, pw)
              if k > 0: break
              why = pfFraming
              break run
          if drained: drained = false
          elif f != nil: k = ingestFramed(c, d, f, short)
          else: k = ingestPlain(c, d)
          if k > 0: break
          if k == InEof and atomicLoad(c.failed, moAcquire):
            why = pfPeer                              # woken by the other direction's failure
            break run
          if k == InEof:
            var e = d
            let a = d.alt
            if d.sinkInAlt and a != nil: e = a     # the sink's state is there
            let fs = e.dstFramer
            if fs != nil:
              let fin = fs.finish
              if fin != nil:
                # The sink's closing record, then the half-close.
                e.wOff = 0
                e.wEnd = 0
                if not fin(c, e):
                  why = pfFraming
                  break run
                while true:
                  let w = emitSome(c, e)
                  if w > 0: break
                  if w != InAgain:
                    why = pfSink
                    code = w
                    break run
                  relayPark(c, d.dst, {evWrite}, res)
                  if res <= 0:
                    why = pfWriteWait
                    code = res
                    break run
            graceful = true
            break run
          if k != InAgain:
            why = pfSource
            code = k
            break run
          sent = 0
          relayReadPark(c, d, res)
          if res <= 0:
            why = pfReadWait
            code = res
            break run
      # The sink: in place, or through the alt block (relayout, or a first
      # span the sink must split), in as many writes as its slots need.
      let viaAlt = d.relayout or (first and tooLong(d))
      first = false
      var alt: nil DirectionPtr = nil
      if viaAlt:
        alt = ensureAlt(d)
        if alt == nil:
          why = pfFraming
          break run
        if not d.relayout:
          moveSinkState(d, alt)          # until the split is out (closeFramers looks there too)
          d.sinkInAlt = true
      var si = 0
      var so = 0
      while true:
        var e = d
        if alt != nil:
          e = alt
          fillAlt(d, alt, si, so)
        if not prepareEmit(c, e):
          why = pfFraming
          break run
        while true:
          let w = emitSome(c, e)
          if w > 0: break
          if w != InAgain:
            why = pfSink
            code = w
            break run
          sent = 0
          relayPark(c, d.dst, {evWrite}, res)
          if res <= 0:
            why = pfWriteWait
            code = res
            break run
        if alt == nil or si >= d.nspans: break
      if alt != nil and not d.relayout:
        moveSinkState(alt, d)
        d.sinkInAlt = false
        giveAlt(alt)                     # a one-time split: the block goes back
        d.alt = nil
      sent = sent + d.bytes
      let sf = d.srcFramer
      if sf == nil: drained = d.bytes < d.slotCount * d.slotMax
      else: drained = short and drainedFramed(d, sf)
      short = false
      when defined(linux):
        spliceNext = not spliceOff and d.bytes >= d.slotMax and spliceable(c, d)
      atomicStore(moved[], moved[] + d.bytes, moRelaxed)
      let h = c.hooks
      if h != nil:
        let ob = h.onBatch
        if ob != nil: ob(c, d, d.bytes)
      d.nspans = 0
      d.wOff = 0
      d.wEnd = 0
      d.iovAt = 0
      d.iovEnd = 0
      let retainedAlt = d.alt
      if retainedAlt != nil:
        retainedAlt.nspans = 0
        retainedAlt.wOff = 0
        retainedAlt.wEnd = 0
        retainedAlt.iovAt = 0
        retainedAlt.iovEnd = 0
      if sent >= YieldBytes:
        sent = 0
        yieldNow()
  when defined(linux): closePipe(pr, pw)
  finishDir(c, d, graceful, why, code)

template startPumps*(c: Conn) =
  ## Lay out both directions, then run direction b as a new task on this
  ## loop while direction a continues in the caller's frame chain. A
  ## framer pair that cannot work together fails the connection.
  if not layout(addr c.a) or not layout(addr c.b):
    failConn(c, "framer geometry")
  else:
    c.refs = 2
    if trySpawnTask(pump(c, addr c.b)):
      pump(c, addr c.a)
    else:
      c.refs = 0
      failConn(c, "runtime shutdown")
