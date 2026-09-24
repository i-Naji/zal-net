## Included by datagram/engine; resolution.
proc startLookup(e: ptr DatagramEngine; slot: int): bool =
  ## Resolve the association's domain off this thread; `dnsDone` applies it.
  let a = addr e.assocs[slot]
  let req = submitResolve(a.dHost.toOpenArray(0, a.dLen - 1), a.dPort, SOCK_DGRAM,
                          a.legFamily, e.inbox, uint64(slot), idOf(e.idx, slot))
  if req == nil: return false
  a.dnsReq = req
  e.dnsOut = e.dnsOut + 1
  result = true

proc sameKey(k: ptr UncheckedArray[byte]; kLen: int; p: ptr UncheckedArray[byte]; n: int): bool {.inline.} =
  if kLen != n: return false
  var i = 0
  while i < n:
    if k[i] != p[i]: return false
    i = i + 1
  result = true

proc forward(e: ptr DatagramEngine; slot: int; pkt: Packet; now: int64) =
  ## Route the datagram and send it, or queue it while its name resolves.
  let v = pkt.dst
  if not valid(v): return
  let data = v.data
  if data == nil: return
  let gen = e.routeGen
  let a = addr e.assocs[slot]
  if v.kind == epIp4 or v.kind == epIp6:
    a.lastDomain = false
    let key = cast[ptr UncheckedArray[byte]](addr a.ipKey[0])
    if a.ipGen != gen or a.ipKind != v.kind or a.ipPort != v.port or
        not sameKey(key, v.len, data, v.len):
      var d = default(Endpoint)
      if not toEndpoint(v, d): return
      a.ipGen = gen
      var oi = 0
      a.ipMode = outMode(e, a, addr d, oi)
      a.ipOut = oi
      if a.ipMode == LegDirect:
        if not ensureLeg(e, slot): a.ipMode = LegNone
        elif v.kind == epIp6 and a.legFamily != AF_INET6: a.ipMode = LegNone
        elif not setIpAddr(a.ipAddr, d.ip.toOpenArray(0, v.len - 1), v.port, a.legFamily):
          a.ipMode = LegNone
      copyMem(addr a.ipKey[0], data, v.len)
      a.ipKind = v.kind
      a.ipPort = v.port
    if a.ipMode == LegDirect: sendFwd(e, a, addr a.ipAddr, pkt.pay, pkt.payLen)
    elif a.ipMode == LegFramed: sendPx(e, slot, a.ipOut, pkt)
    return
  a.lastDomain = true
  let name = data
  let hostKey = cast[ptr UncheckedArray[byte]](addr a.dHost[0])
  if a.dPort != v.port or not sameKey(hostKey, a.dLen, name, v.len):
    if a.dnsReq != nil: return        # one lookup in flight per association
    copyMem(addr a.dHost[0], name, v.len)
    a.dLen = v.len
    a.dPort = v.port
    a.dnsState = DnsNone
    a.dGen = 0
  # A name a rule wants resolved routes once its lookup is known.
  let known = a.dnsState == DnsOk or (a.dnsState == DnsFailed and now - a.cacheUnix < DnsFailSec)
  if a.dGen != gen or (a.dMode == LegResolve and known):
    var d = default(Endpoint)
    if not toEndpoint(v, d): return
    var oi = 0
    a.dMode = outMode(e, a, addr d, oi, known)
    a.dOut = oi
    a.dGen = gen
  if a.dMode == LegResolve:
    if not ensureLeg(e, slot): return
    if a.dnsState == DnsPending:
      queuePending(e, a, pkt.pay, pkt.payLen)
    elif a.dnsReq == nil and startLookup(e, slot):
      a.dnsState = DnsPending
      queuePending(e, a, pkt.pay, pkt.payLen)
    return
  if a.dMode == LegFramed:
    sendPx(e, slot, a.dOut, pkt)   # the server resolves the name
    return
  if a.dMode != LegDirect or not ensureLeg(e, slot): return
  if a.dnsState == DnsOk:
    # Serve a stale address while a refresh runs.
    if now - a.cacheUnix >= DnsCacheSec and a.dnsReq == nil: discard startLookup(e, slot)
    sendFwd(e, a, addr a.cacheAddr, pkt.pay, pkt.payLen)
  elif a.dnsState == DnsPending:
    queuePending(e, a, pkt.pay, pkt.payLen)
  elif a.dnsState == DnsFailed and now - a.cacheUnix < DnsFailSec:
    discard
  elif a.dnsReq == nil and startLookup(e, slot):
    a.dnsState = DnsPending
    queuePending(e, a, pkt.pay, pkt.payLen)

proc pickAddr(addrs: ptr UncheckedArray[SockAddrBuf]; n: int): int =
  ## An IPv4 address (plain or mapped) when the name has one: a datagram
  ## gets no connect error to fall back on, and IPv4 reaches more hosts.
  result = 0
  var i = 0
  while i < n:
    let raw = cast[ptr UncheckedArray[byte]](addr addrs[i].ss)
    let fam = cint(addrs[i].ss.ss_family)
    if fam == AF_INET: return i
    if fam == AF_INET6 and raw[18] == 0xff and raw[19] == 0xff:
      var zero = true
      var k = 8
      while k < 18:
        if raw[k] != 0: zero = false
        k = k + 1
      if zero: return i
    i = i + 1

proc disposeSetup(j: JobPtr) {.nimcall.} =
  let setup = cast[ptr LegSetupJob](j)
  if setup.ctlFd >= 0: discard closeRaw(setup.ctlFd)

proc setupDone(e: ptr DatagramEngine; job: ptr LegSetupJob; now: int64) =
  ## A leg's handshake finished: adopt its control connection and send what
  ## waited, or note the failure. One nobody waits for any more has its
  ## control connection closed here.
  let slot = int(job.job.tag - SetupTag)
  var adopted = false
  if slot >= 0 and slot < e.assocs.len and isLive(e.idx, slot) and
     idOf(e.idx, slot) == job.job.tag2 and e.assocs[slot].pxJob == job:
    let a = addr e.assocs[slot]
    a.pxJob = nil
    releaseJob(addr job.job)   # the association's reference
    if job.ok and job.ctlFd >= 0 and watchEngine(e, job.ctlFd, CtlBase + uint64(slot)):
      adopted = true
      a.pxCtl = job.ctlFd
      job.ctlFd = -1
      a.pxAddr = job.relay
      a.pxReady = true
      a.pxFailUnix = 0
      let pend = a.pxPend
      if pend != nil:
        var o = 0
        while o + 2 <= a.pxPendLen:
          let len = (int(pend[o]) shl 8) or int(pend[o + 1])
          discard sockSendto(a.pxFd, addr pend[o + 2], csize_t(len), 0, addr a.pxAddr.ss, a.pxAddr.len)
          o = o + 2 + len
        dealloc(pend)
        a.pxPend = nil
        a.pxPendLen = 0
    else:
      a.pxFailUnix = now
      closePx(e, a)
  if not adopted and job.ctlFd >= 0:
    discard closeRaw(job.ctlFd)
    job.ctlFd = -1

proc ctlReady(e: ptr DatagramEngine; slot: int) =
  ## The leg's control connection: EOF or an error ends the leg (the next
  ## datagram sets up another); stray bytes are dropped.
  let a = addr e.assocs[slot]
  var buf = default(array[256, byte])
  let n = readSome(a.pxCtl, addr buf[0], buf.len)
  if n <= 0 and n != IoAgain: closePx(e, a)

proc dnsDone(e: ptr DatagramEngine; req: ptr ResolveJob; now: int64) =
  ## Apply a finished lookup; a stale one (association gone or replaced)
  ## is ignored.
  let slot = int(req.job.tag)
  if slot < 0 or slot >= e.assocs.len or not isLive(e.idx, slot): return
  let a = addr e.assocs[slot]
  if idOf(e.idx, slot) != req.job.tag2 or a.dnsReq != req: return
  a.dnsReq = nil
  releaseJob(addr req.job)   # the association's reference
  var addrs {.noinit.}: array[MaxAddrs, SockAddrBuf]
  let n = resolveResult(req, cast[ptr UncheckedArray[SockAddrBuf]](addr addrs[0]))
  if n > 0:
    a.cacheAddr = addrs[pickAddr(cast[ptr UncheckedArray[SockAddrBuf]](addr addrs[0]), n)]
    a.dnsState = DnsOk
    a.cacheUnix = now
  elif a.dnsState == DnsOk:
    # A failed refresh keeps the old address and retries later.
    a.cacheUnix = now - DnsCacheSec + DnsFailSec
  else:
    a.dnsState = DnsFailed
    a.cacheUnix = now
  if a.dMode == LegResolve:
    var d = default(Endpoint)
    d.kind = epName
    d.port = a.dPort
    d.hostLen = a.dLen
    copyMem(addr d.host[0], addr a.dHost[0], a.dLen)
    var oi = 0
    a.dMode = outMode(e, a, addr d, oi, true)
    a.dOut = oi
    if a.dMode == LegDirect and not ensureLeg(e, slot): a.dMode = LegNone
  flushPending(e, slot)

# ----------------------------------------------------------------- datagrams

