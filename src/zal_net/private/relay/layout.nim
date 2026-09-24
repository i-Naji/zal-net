## Included by relay/conn; record geometry and relayout buffers.
# ------------------------------------------------------------------ layout

const PlainGeometry = Geometry(head: 0, tail: 0, maxRecord: MaxRecord, headRoom: 0)

proc geometryOf(f: nil Framer): Geometry {.inline.} =
  if f == nil: PlainGeometry else: f.geometry

proc sane(g: Geometry): bool =
  ## A geometry the buffer can hold: sizes in range, the room before the
  ## first payload within HeadRoom, and at least one record per buffer.
  g.head >= 0 and g.tail >= 0 and g.headRoom >= 0 and
    g.maxRecord >= 1 and g.maxRecord <= MaxRecord and
    max(g.head, g.headRoom) <= HeadRoom and
    g.head + g.maxRecord + g.tail <= BufCap - HeadRoom

proc ensureAlt(d: DirectionPtr; payloadNeeded = true): nil DirectionPtr =
  ## The direction's alt block (sink-shaped slots), mapped on first use; nil
  ## when mapping fails.
  var a = d.alt
  if a == nil:
    a = takeAlt()
    if a == nil: return nil
    d.alt = a
  if payloadNeeded and not ensurePayload(a): return nil
  a.src = -1
  a.dst = d.dst
  a.srcFramer = nil
  a.slotStride = d.slotStride
  a.slotMax = d.slotMax
  a.slotCount = d.slotCount
  result = a

proc moveSinkState(src, dst: DirectionPtr) =
  ## The sink's framer, state words and pending prefix move to `dst`.
  dst.dstFramer = src.dstFramer
  copyMem(addr dst.dstSt[0], addr src.dstSt[0], sizeof(src.dstSt))
  zeroMem(addr src.dstSt[0], sizeof(src.dstSt))
  dst.preLen = src.preLen
  dst.preAt = src.preAt
  if src.preLen > 0: copyMem(addr dst.pre[0], addr src.pre[0], src.preLen)
  src.preLen = 0
  src.preAt = 0

proc fillAlt(d, a: DirectionPtr; si, so: var int) =
  ## Copy the batch's payload from span `si`, byte `so`, into a's buffer as
  ## back-to-back sink records (head, payload, tail), split at the sink's
  ## record size, until the buffer or the spans run out.
  let g = geometryOf(a.dstFramer)
  var at = HeadRoom                      # the next payload; its head goes before it
  var j = 0
  var total = 0
  while j < MaxSpans and si < d.nspans:
    let sp = d.spans[si]
    let n = min(g.maxRecord, sp.len - so)
    if at + n + g.tail > BufCap: break
    copyMem(bufAt(a, at), bufAt(d, sp.off + so), n)
    a.spans[j] = Span(off: at, len: n)
    total = total + n
    j = j + 1
    at = at + n + g.tail + g.head
    so = so + n
    if so == sp.len:
      si = si + 1
      so = 0
  a.nspans = j
  a.bytes = total

proc tooLong(d: DirectionPtr): bool =
  ## A span the sink cannot seal where it lies (a handshake's leftover):
  ## longer than its record, or without its head or tail room (the buffer's
  ## end, or a framed source's bytes not yet read).
  result = false
  let f = d.dstFramer
  if f == nil: return
  let g = f.geometry
  for i in 0 ..< d.nspans:
    let sp = d.spans[i]
    if sp.len > g.maxRecord or sp.off < g.head or sp.off + sp.len + g.tail > BufCap: return true
    # A framed source's unread bytes start at d.off: a tail must not reach them.
    if d.srcFramer != nil and sp.off + sp.len + g.tail > d.off: return true

proc layout(d: DirectionPtr): bool =
  ## Cache a plain source's slots (the sink's geometry) and a framed
  ## source's largest wire record; a framed source whose records leave the
  ## sink too little head, tail or record size is relaid out (the sink's
  ## state moves to the alt block). False when a geometry is not sane
  ## (see `sane`) or no alt block can be mapped.
  let s = geometryOf(d.srcFramer)
  let k = geometryOf(d.dstFramer)
  if not sane(s) or not sane(k): return false
  d.slotStride = k.head + k.maxRecord + k.tail
  d.slotMax = k.maxRecord
  d.slotCount = min(MaxSpans, (BufCap - HeadRoom) div d.slotStride)
  d.inStride = s.head + s.maxRecord + s.tail
  if d.srcFramer != nil and d.dstFramer != nil and
     (k.head > s.head or k.tail > s.tail or k.maxRecord < s.maxRecord):
    let a = ensureAlt(d, false)
    if a == nil: return false
    d.relayout = true
    moveSinkState(d, a)                  # the sink seals in the alt block from now on
    d.sinkInAlt = true
  result = true

proc slotOff*(d: DirectionPtr; i: int): int {.inline.} =
  ## Where a plain source's slot `i` puts its payload (after `layout`).
  HeadRoom + i * d.slotStride

