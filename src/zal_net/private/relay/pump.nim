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

proc ingestFramed(c: Conn; d: DirectionPtr; f: Framer): int {.noinline.} =
  ## Decode what is buffered (`f` is d.srcFramer); read more until a batch
  ## is ready.
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

# ----------------------------------------------------------- plain source

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
  var i = 0
  while i < d.slotCount:
    d.iov[i].iov_base = bufAt(d, slotOff(d, i))
    d.iov[i].iov_len = csize_t(d.slotMax)
    i = i + 1
  let n = readvSome(d.src, addr d.iov[0], d.slotCount)
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
      let n = writevSome(d.dst, addr d.iov[d.iovAt], d.iovEnd - d.iovAt)
      if n > 0:
        touchIo(addr c.lastIo)
        advanceWritten(d, n)
      elif n == IoAgain:
        return InAgain
      else:
        return InFail
  result = 1

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
  let moved = if d == addr c.a: addr c.upBytes else: addr c.downBytes
  block run:
    while true:
      if d.nspans == 0:
        while true:
          let f = d.srcFramer
          let k = if f != nil: ingestFramed(c, d, f) else: ingestPlain(c, d)
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
