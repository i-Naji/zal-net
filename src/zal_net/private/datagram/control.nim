## Included by datagram/engine; control.
proc unbind(l: ptr Listener) =
  let old = l.kind
  if old != nil:
    let unbind = old.unbindListener
    if unbind != nil: unbind(l)

proc setListenerCodec*(e: ptr DatagramEngine; slot: int; codec: nil ptr ListenerCodec;
                       settings: nil pointer; tagId: int32; label: int) =
  ## Serve listener `slot` with `codec` (nil: drop its datagrams). Engine
  ## thread only (hooks, `MsgCall`).
  if slot < 0 or slot >= e.listeners.len or not e.listeners[slot].used: return
  let l = addr e.listeners[slot]
  unbind(l)
  l.kind = codec
  l.settings = settings
  l.tagId = tagId
  l.label = label
  l.cst = default(array[ListenerWords, uint64])
  if codec != nil:
    let bindL = codec.bindListener
    if bindL != nil and not bindL(e, l): l.kind = nil

proc lookupPx(e: ptr DatagramEngine; oi: int; now: int64) =
  ## Resolve entry `oi`'s server: at once for an address, on the blocking
  ## pool for a name.
  let px = addr e.px[oi]
  let k = px.kind
  if k == nil: return
  let server = k.legServer
  let settings = px.settings
  if server == nil or settings == nil: return
  let d = server(settings)
  if d.kind == epIp4 or d.kind == epIp6:
    if endpointSockAddr(d[], e.legFamily, px.sa):
      px.state = DnsOk
      px.unix = high(int64) div 2      # never refreshed
    else:
      px.state = DnsFailed
      px.unix = now
    return
  if d.kind != epName or px.req != nil: return
  let req = submitResolve(d.host.toOpenArray(0, d.hostLen - 1), d.port, SOCK_DGRAM, e.legFamily,
                          e.inbox, PxTag + uint64(oi), uint64(px.gen))
  if req == nil: return
  px.req = req
  e.dnsOut = e.dnsOut + 1
  if px.state != DnsOk: px.state = DnsPending

proc pxDone(e: ptr DatagramEngine; req: ptr ResolveJob; now: int64) =
  let oi = int(req.job.tag - PxTag)
  if oi < 0 or oi >= e.px.len: return
  let px = addr e.px[oi]
  if uint64(px.gen) != req.job.tag2 or px.req != req: return
  px.req = nil
  releaseJob(addr req.job)   # ours
  var addrs {.noinit.}: array[MaxAddrs, SockAddrBuf]
  let n = resolveResult(req, cast[ptr UncheckedArray[SockAddrBuf]](addr addrs[0]))
  if n > 0:
    px.sa = addrs[pickAddr(cast[ptr UncheckedArray[SockAddrBuf]](addr addrs[0]), n)]
    px.state = DnsOk
    px.unix = now
  elif px.state == DnsOk:
    px.unix = now - DnsCacheSec + DnsFailSec   # keep the old address, retry later
  else:
    px.state = DnsFailed
    px.unix = now

proc forgetPx(e: ptr DatagramEngine) =
  var i = 0
  while i < e.px.len:
    let req = e.px[i].req
    if req != nil: releaseJob(addr req.job)
    i = i + 1
  e.px = @[]

proc refreshPx(e: ptr DatagramEngine; now: int64) =
  ## Look up proxy servers whose address is missing, failed a while ago,
  ## or is old.
  var i = 0
  while i < e.px.len:
    let px = addr e.px[i]
    if px.gen != 0 and px.req == nil and
       (px.state == DnsNone or
        (px.state == DnsFailed and now - px.unix >= DnsFailSec) or
        (px.state == DnsOk and now - px.unix >= DnsCacheSec)):
      lookupPx(e, i, now)
    i = i + 1

proc invalidateRoutes*(e: ptr DatagramEngine) =
  ## Every association routes its next datagram again (after a reload).
  ## Engine thread only.
  e.routeGen = e.routeGen + 1

proc setLegs*(e: ptr DatagramEngine; n: int) =
  ## A new leg table of `n` entries (empty until `setLeg`). Cached routes
  ## hold indices into the old one, so they are invalidated. Engine thread
  ## only.
  if n < 0: return
  forgetPx(e)
  e.px = newSeq[PxServer](n)
  invalidateRoutes(e)

proc setLeg*(e: ptr DatagramEngine; i: int; kind: ptr LegKind; settings: pointer; key: uint64) =
  ## Entry `i`: a framed leg kind and its settings. An association's leg
  ## survives while its entry keeps the same `key` and kind. Engine thread
  ## only.
  if i < 0 or i >= e.px.len or kind.legStateSize < 0 or
      kind.legOverhead < 0 or kind.legOverhead > UdpMax: return
  let px = addr e.px[i]
  let old = px.req
  px.req = nil
  if old != nil: releaseJob(addr old.job)
  invalidateRoutes(e)
  px.state = DnsNone
  px.sa = default(SockAddrBuf)
  px.kind = kind
  px.settings = settings
  px.key = key
  px.gen = e.routeGen
  if kind.legServer != nil: lookupPx(e, i, unixSec())

proc removeInbound(e: ptr DatagramEngine; slot: int) =
  let ib = addr e.listeners[slot]
  var i = 0
  while i < e.assocs.len:
    if isLive(e.idx, i) and e.assocs[i].inb == slot: dropAssoc(e, i, EndRemoved)
    i = i + 1
  unbind(ib)
  closeEngineFd(e, ib.fd)
  ib[] = default(Listener)
  ib.fd = -1

proc handleMsg(e: ptr DatagramEngine; m: ptr EngineMsg) =
  m.ok = false
  if not e.running:
    if m.op == MsgAdd and m.fd >= 0:
      discard closeRaw(m.fd)
      m.fd = -1
    return
  case m.op
  of MsgAdd:
    var slot = -1
    var i = 0
    while i < e.listeners.len and slot < 0:
      if not e.listeners[i].used: slot = i
      i = i + 1
    if slot >= 0 and watchEngine(e, m.fd, uint64(slot)):
      let ib = addr e.listeners[slot]
      ib.used = true
      ib.fd = m.fd
      ib.id = m.id
      discard groOn(m.fd)
      ib.label = -1
      let codec = m.codec
      let h = e.hooks
      if codec != nil:
        setListenerCodec(e, slot, codec, m.settings, m.tag, -1)
      elif h != nil:
        let added = h.listenerAdded
        if added != nil: added(e, slot)
      m.ok = true
    else:
      discard closeRaw(m.fd)
  of MsgRemove:
    var i = 0
    while i < e.listeners.len:
      if e.listeners[i].used and e.listeners[i].id == m.id:
        removeInbound(e, i)
        m.ok = true
      i = i + 1
  of MsgStop:
    e.running = false
    m.ok = true
  of MsgCall:
    if m.call != nil:
      m.call(e, m)
  else: discard

template drainInbox(e: ptr DatagramEngine; now: int64) =
  var j = takeCompleted(e.inbox[])
  while j != nil:
    let next = nextJob(j)
    if j.tag == MsgTag:
      handleMsg(e, cast[ptr EngineMsg](j))
      if e.retired.len != 0: drainRetired(e)
      atomicStore(cast[ptr EngineMsg](j).done, 1, moRelease)
    elif j.tag >= SetupTag:
      e.dnsOut = e.dnsOut - 1
      setupDone(e, cast[ptr LegSetupJob](j), now)
    elif j.tag >= PxTag:
      e.dnsOut = e.dnsOut - 1
      pxDone(e, cast[ptr ResolveJob](j), now)
    else:
      e.dnsOut = e.dnsOut - 1
      dnsDone(e, cast[ptr ResolveJob](j), now)
    releaseJob(j)   # the delivered reference
    j = next

proc tick(e: ptr DatagramEngine; now: int64; replies: var MmsgBatch) =
  ## Expire idle associations, end those whose owner is not alive, report
  ## bytes; refresh leg servers' addresses.
  refreshPx(e, now)
  var i = 0
  while i < e.assocs.len:
    if isLive(e.idx, i):
      let a = addr e.assocs[i]
      if not stillOwned(e, a):          # before idle: a kick is the better reason
        dropAssoc(e, i, EndKicked)
      elif now - a.lastUnix > e.natSec:
        # A delayed readiness continuation does not make queued traffic idle.
        if a.legFd >= 0: legReady(e, i, replies, now)
        if a.pxFd >= 0: pxReady(e, i, replies, now)
        if now - a.lastUnix > e.natSec: dropAssoc(e, i, EndIdle)
      else:
        flushBytes(e, a)
    i = i + 1

# ----------------------------------------------------------------- the thread

