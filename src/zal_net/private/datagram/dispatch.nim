## Included by datagram/engine; dispatch.
proc receiveAdaptive(adaptive: bool; budget: var ReceiveBudget;
                     fd: cint; batch: var MmsgBatch): int =
  let maximum = if adaptive: target(budget) else: batch.cap
  result = recvmmsgBatch(fd, batch, MSG_DONTWAIT, maximum)
  if adaptive: observe(budget, result)

proc stillOwned(e: ptr DatagramEngine; a: ptr Assoc): bool {.inline.} =
  let owner = a.owner
  if owner == nil: return true
  let h = e.hooks
  if h == nil: return true
  let alive = h.alive
  result = alive == nil or alive(e, a, owner)

proc handleDatagram(e: ptr DatagramEngine; ib: int; codec: ptr ListenerCodec;
                    p: ptr UncheckedArray[byte]; n: int;
                    peer: ptr SockaddrStorage; peerLen: cuint; now: int64) =
  var pkt = Packet(slot: -1, pay: p, payLen: 0)   # empty views of the datagram
  if not codec.open(e, ib, p, n, peer, peerLen, now, pkt): return
  if pkt.payLen < 0 or pkt.payLen > UdpMax or not isLive(e.idx, pkt.slot): return
  let a = addr e.assocs[pkt.slot]
  if not stillOwned(e, a):
    dropAssoc(e, pkt.slot, EndKicked)
    return
  a.lastUnix = now
  forward(e, pkt.slot, pkt, now)

proc inboundReady(e: ptr DatagramEngine; ib: int; b: var MmsgBatch; now: int64) =
  let n = receiveAdaptive(e.adaptiveBatching, e.inBudget, e.listeners[ib].fd, b)
  let codec = e.listeners[ib].kind
  if n <= 0 or codec == nil: return
  var k = 0
  while k < n:
    # A GRO-coalesced datagram holds several client datagrams.
    let total = datagramLen(b, k)
    var seg = groSegment(b, k)
    if seg <= 0 or seg > total: seg = total
    var off = 0
    while true:
      let len = min(seg, total - off)
      handleDatagram(e, ib, codec, cast[ptr UncheckedArray[byte]](addr b.slots[k].buf[off]), len,
                     addr b.slots[k].name, peerLen(b, k), now)
      off = off + len
      if off >= total: break
    k = k + 1
  flushRun(e.tx, addr e.fwd, false)

proc emitReply(e: ptr DatagramEngine; slot: int; fd: cint; src: EndpointView;
               pay: ptr UncheckedArray[byte]; len: int; now: int64) =
  ## Seal a reply for the association's client and stage it: in the
  ## sendmmsg batch without GSO, else in the reply run.
  let a = addr e.assocs[slot]
  let k = a.kind
  if len < 0 or k.replyOverhead < 0 or k.replyOverhead > UdpMax or
      len > UdpMax - k.replyOverhead: return
  let capacity = len + k.replyOverhead
  if e.tx.gsoOff or capacity == 0:
    if e.tx.outN == e.tx.outB.cap: flushOut(e.tx, fd)
    let p = cast[ptr UncheckedArray[byte]](addr e.tx.outB.slots[e.tx.outN].buf[0])
    let sz = k.sealReply(e, slot, src, pay, len, p, capacity, now)
    if sz >= 0 and sz <= capacity and (sz > 0 or k.emptyReplies):
      setOutgoing(e.tx.outB[], e.tx.outN, sz, a.peer)
      e.tx.outN = e.tx.outN + 1
      a.down = a.down + len
  else:
    let p = runRoom(e.tx, addr e.reply, fd, a.peer, len + k.replyOverhead, true)
    let sz = k.sealReply(e, slot, src, pay, len, p, capacity, now)
    if sz == 0 and k.emptyReplies:
      flushRun(e.tx, addr e.reply, true)
      flushOut(e.tx, fd)
      discard sockSendto(fd, p, 0, 0, addr a.peer.ss, a.peer.len)
    elif sz > 0 and sz <= capacity:
      runCommit(e.tx, addr e.reply, sz, true)
      a.down = a.down + len

proc replyFd(e: ptr DatagramEngine; a: ptr Assoc): cint {.inline.} =
  ## The listener to answer through, or -1 when its codec no longer serves
  ## it (the listener is being removed or changed type).
  let ibp = addr e.listeners[a.inb]
  result = if ibp.kind != nil and ibp.kind == a.kind: ibp.fd else: -1

proc legReady(e: ptr DatagramEngine; slot: int; b: var MmsgBatch; now: int64) =
  ## Replies from the destinations of one association. A GRO-coalesced
  ## datagram is split at its segment size; each piece is sealed separately.
  let a = addr e.assocs[slot]
  let n = receiveAdaptive(e.adaptiveBatching, e.legBudget, a.legFd, b)
  if n <= 0: return
  let fd = replyFd(e, a)
  if fd < 0: return
  var i = 0
  while i < n:
    let total = datagramLen(b, i)
    let src = socketEndpointView(addr b.slots[i].name, peerLen(b, i))
    var seg = groSegment(b, i)
    if seg <= 0 or seg > total: seg = total
    var off = 0
    while valid(src):
      let len = min(seg, total - off)
      emitReply(e, slot, fd, src, cast[ptr UncheckedArray[byte]](addr b.slots[i].buf[off]),
                len, now)
      off = off + len
      if off >= total: break
    i = i + 1
  flushRun(e.tx, addr e.reply, true)
  flushOut(e.tx, fd)
  a.lastUnix = now

proc sameSock(x: ptr SockaddrStorage; y: ptr SockaddrStorage): bool =
  ## Same family, address and port (not the length byte, flow label or
  ## scope some systems fill in).
  if x.ss_family != y.ss_family: return false
  let p = cast[ptr UncheckedArray[byte]](x)
  let q = cast[ptr UncheckedArray[byte]](y)
  let fam = cint(x.ss_family)
  if fam == AF_INET:
    var i = 2
    while i < 8:
      if p[i] != q[i]: return false
      i = i + 1
  elif fam == AF_INET6:
    if p[2] != q[2] or p[3] != q[3]: return false
    var i = 8
    while i < 24:
      if p[i] != q[i]: return false
      i = i + 1
  else:
    return false
  result = true

proc pxReady(e: ptr DatagramEngine; slot: int; b: var MmsgBatch; now: int64) =
  ## Datagrams from the association's proxy server: decoded by the
  ## leg kind in place, sealed for the client.
  let a = addr e.assocs[slot]
  let n = receiveAdaptive(e.adaptiveBatching, e.legBudget, a.pxFd, b)
  if n <= 0: return
  let fd = replyFd(e, a)
  if fd < 0: return
  let lk = a.pxKind
  let st = a.pxState
  if st == nil: return
  var i = 0
  while i < n:
    if sameSock(addr a.pxAddr.ss, addr b.slots[i].name):
      let total = datagramLen(b, i)
      var seg = groSegment(b, i)
      if seg <= 0 or seg > total: seg = total
      var off = 0
      while off < total:
        let len = min(seg, total - off)
        let p = cast[ptr UncheckedArray[byte]](addr b.slots[i].buf[off])
        var src = default(EndpointView)
        var po = 0
        var pl = 0
        if lk.legRecv(st, p, len, now, src, po, pl) and valid(src) and
            po >= 0 and pl >= 0 and po <= len and pl <= len - po:
          emitReply(e, slot, fd, src,
                    cast[ptr UncheckedArray[byte]](addr p[po]), pl, now)
        off = off + len
    i = i + 1
  flushRun(e.tx, addr e.reply, true)
  flushOut(e.tx, fd)
  a.lastUnix = now

# ------------------------------------------------------------------ control

