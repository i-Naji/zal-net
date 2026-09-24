## Included by datagram/engine; legs.
proc ensureLeg(e: ptr DatagramEngine; slot: int): bool =
  ## The association's direct socket, opened on first use.
  let a = addr e.assocs[slot]
  if a.legFd >= 0: return true
  var family: cint = 0
  let fd = openUdpSocket(family)
  if fd < 0: return false
  discard groOn(fd)
  if not watchEngine(e, fd, LegBase + uint64(slot)):
    discard closeRaw(fd)
    return false
  a.legFd = fd
  a.legFamily = family
  result = true

var gDirectLeg* = LegKind(mode: LegDirect)   ## a route's leg: send from the association's socket
var gBlockLeg* = LegKind(mode: LegBlock)     ## a route's leg: drop

proc outMode(e: ptr DatagramEngine; a: ptr Assoc; d: ptr Endpoint; oi: var int; resolved = false): int =
  ## The mode of the leg the route hook picks for `d` (its leg table index
  ## in `oi`), or LegResolve. Without a route hook, everything goes direct.
  ## `resolved`: the name's address is `cacheAddr` (none when the lookup
  ## failed).
  var ch = LegChoice(kind: addr gDirectLeg, leg: -1, tag: -1)
  let h = e.hooks
  if h != nil:
    let route = h.route
    if route != nil:
      let n = if resolved and a.dnsState == DnsOk: 1 else: 0
      if route(e, a, d, resolved, cast[ptr UncheckedArray[SockAddrBuf]](addr a.cacheAddr), n, ch) == rrResolve:
        return LegResolve
  oi = ch.leg
  a.outTag = ch.tag
  a.dsts = a.dsts + 1
  let k = ch.kind
  result = if k == nil: LegNone else: k.mode

proc disposeSetup(j: JobPtr) {.nimcall.}

proc ensurePx(e: ptr DatagramEngine; slot, oi: int): nil pointer =
  ## The association's leg to entry `oi`'s server, opened (or replaced)
  ## as needed: the leg's state. nil when the server has no address yet or
  ## the leg cannot be made.
  result = nil
  let a = addr e.assocs[slot]
  if oi < 0 or oi >= e.px.len: return
  let k = e.px[oi].kind
  if k == nil or e.px[oi].state != DnsOk: return
  let tag = e.px[oi].key
  if a.pxFd >= 0 and a.pxKind == k and a.pxTag == tag:
    if k.legSetup == nil and not sameAddr(a.pxAddr, e.px[oi].sa): a.pxAddr = e.px[oi].sa
    return a.pxState
  let settings = e.px[oi].settings
  if settings == nil: return
  closePx(e, a)
  let now = unixSec()
  if k.legSetup != nil and a.pxFailUnix != 0 and now - a.pxFailUnix < DnsFailSec: return
  var family: cint = 0
  let fd = openUdpSocket(family)
  if fd < 0: return
  discard groOn(fd)
  if not watchEngine(e, fd, PxBase + uint64(slot)):
    discard closeRaw(fd)
    return
  a.pxFd = fd
  a.pxKind = k
  a.pxTag = tag
  a.pxAddr = e.px[oi].sa
  let st = alloc0(max(8, k.legStateSize))
  a.pxState = st
  if st == nil or not k.legOpen(st, settings):
    closePx(e, a)
    return
  let setup = k.legSetup
  if setup == nil:
    a.pxReady = true
    return st
  # A handshake first, on the blocking pool, with a copy of the leg's state.
  let port = bindEphemeral(fd, family)
  if port == 0 or k.legStateSize > LegSetupWords * 8:
    closePx(e, a)
    return
  let job = cast[ptr LegSetupJob](newJob(sizeof(LegSetupJob), setup, disposeSetup))
  job.server = e.px[oi].sa
  job.family = family
  job.localPort = port
  job.ctlFd = -1
  copyMem(addr job.st[0], st, k.legStateSize)
  job.job.tag = SetupTag + uint64(slot)
  job.job.tag2 = idOf(e.idx, slot)
  if not spawnBlocking(addr job.job, e.inbox):
    releaseJob(addr job.job)
    closePx(e, a)
    return
  a.pxJob = job
  e.dnsOut = e.dnsOut + 1
  result = st

type PendBytes = nil ptr UncheckedArray[byte]   # `var nil ptr T` does not parse as a parameter type

proc pendBuf(p: var PendBytes; len: var int; capacity: int): ptr UncheckedArray[byte] =
  ## A pending queue's buffer, allocated on first use.
  let cur = p
  if cur != nil: return cur
  let fresh = cast[ptr UncheckedArray[byte]](alloc(capacity))
  p = fresh
  len = 0
  result = fresh

proc queuePx(e: ptr DatagramEngine; a: ptr Assoc; st: pointer; pkt: Packet) =
  ## Frame a datagram while the leg's setup runs. Bounded, like `pend`.
  let k = a.pxKind
  if k.legOverhead < 0 or k.legOverhead > UdpMax or pkt.payLen > UdpMax - k.legOverhead: return
  let need = pkt.payLen + k.legOverhead
  let buf = pendBuf(a.pxPend, a.pxPendLen, e.pendingCap)
  if a.pxPendLen + 2 + need > e.pendingCap: return
  let sz = k.legSeal(st, pkt.dst, pkt.pay, pkt.payLen,
                     cast[ptr UncheckedArray[byte]](addr buf[a.pxPendLen + 2]), need, unixSec())
  if sz <= 0 or sz > need: return
  buf[a.pxPendLen] = byte(sz shr 8)
  buf[a.pxPendLen + 1] = byte(sz and 0xff)
  a.pxPendLen = a.pxPendLen + 2 + sz
  a.up = a.up + pkt.payLen

proc sendPx(e: ptr DatagramEngine; slot, oi: int; pkt: Packet) =
  ## Frame the datagram for the leg's server and send it in a run.
  let st = ensurePx(e, slot, oi)
  if st == nil: return
  let a = addr e.assocs[slot]
  if not a.pxReady:
    queuePx(e, a, st, pkt)
    return
  let k = a.pxKind
  if k.legOverhead < 0 or k.legOverhead > UdpMax or pkt.payLen > UdpMax - k.legOverhead: return
  let capacity = pkt.payLen + k.legOverhead
  let q = runRoom(e.tx, addr e.fwd, a.pxFd, a.pxAddr, capacity, false)
  let sz = k.legSeal(st, pkt.dst, pkt.pay, pkt.payLen, q, capacity, unixSec())
  if sz > 0 and sz <= capacity:
    runCommit(e.tx, addr e.fwd, sz, false)
    a.up = a.up + pkt.payLen

proc sendFwd(e: ptr DatagramEngine; a: ptr Assoc; sa: ptr SockAddrBuf; pay: ptr UncheckedArray[byte];
             payLen: int) =
  if e.tx.gsoOff or payLen == 0:
    flushRun(e.tx, addr e.fwd, false)
    discard sockSendto(a.legFd, pay, csize_t(payLen), 0, addr sa.ss, sa.len)
  else:
    let q = runRoom(e.tx, addr e.fwd, a.legFd, sa[], payLen, false)
    copyMem(addr q[0], pay, payLen)
    runCommit(e.tx, addr e.fwd, payLen, false)
  a.up = a.up + payLen

proc queuePending(e: ptr DatagramEngine; a: ptr Assoc; p: pointer; len: int) =
  ## Hold a datagram while its destination name resolves. Bounded; the
  ## overflow is dropped like any datagram under pressure.
  let buf = pendBuf(a.pend, a.pendLen, e.pendingCap)
  if a.pendLen + 2 + len > e.pendingCap: return
  buf[a.pendLen] = byte(len shr 8)
  buf[a.pendLen + 1] = byte(len and 0xff)
  if len > 0: copyMem(addr buf[a.pendLen + 2], p, len)
  a.pendLen = a.pendLen + 2 + len

proc flushPending(e: ptr DatagramEngine; slot: int) =
  let a = addr e.assocs[slot]
  let pend = a.pend
  if pend == nil: return
  if a.dMode == LegFramed:
    # Routed after its lookup (resolve rules): the server gets the name.
    let dst = EndpointView(kind: epName, port: a.dPort, len: a.dLen,
                           data: cast[ptr UncheckedArray[byte]](addr a.dHost[0]))
    var o = 0
    while o + 2 <= a.pendLen:
      let len = (int(pend[o]) shl 8) or int(pend[o + 1])
      sendPx(e, slot, a.dOut, Packet(slot: slot, dst: dst,
                                     pay: cast[ptr UncheckedArray[byte]](addr pend[o + 2]), payLen: len))
      o = o + 2 + len
    flushRun(e.tx, addr e.fwd, false)
  elif a.dnsState == DnsOk and a.dMode == LegDirect and a.legFd >= 0:
    var o = 0
    while o + 2 <= a.pendLen:
      let len = (int(pend[o]) shl 8) or int(pend[o + 1])
      discard sockSendto(a.legFd, addr pend[o + 2], csize_t(len), 0,
                     addr a.cacheAddr.ss, a.cacheAddr.len)
      a.up = a.up + len
      o = o + 2 + len
  dealloc(pend)
  a.pend = nil
  a.pendLen = 0

