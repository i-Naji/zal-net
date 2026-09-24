## Included by datagram/engine; associations.
proc mixId(id: uint64; ib: int): uint64 {.inline.} =
  ## Ids are per listener: the same client may use two listeners.
  id xor (uint64(ib + 1) * 0x9E3779B97F4A7C15'u64)

proc resetAssoc(a: ptr Assoc) =
  a[] = default(Assoc)
  a.legFd = -1
  a.pxFd = -1
  a.pxCtl = -1

proc growRecords(e: ptr DatagramEngine) =
  if e.assocs.len < e.idx.cap:
    let old = e.assocs.len
    e.assocs.setLen(e.idx.cap)
    var i = old
    while i < e.assocs.len:
      e.assocs[i].legFd = -1
      e.assocs[i].pxFd = -1
      e.assocs[i].pxCtl = -1
      i = i + 1

proc assocAt*(e: ptr DatagramEngine; slot: int): ptr Assoc {.inline.} = addr e.assocs[slot]

proc flushBytes(e: ptr DatagramEngine; a: ptr Assoc) =
  if a.up > 0 or a.down > 0:
    let h = e.hooks
    if h != nil and h.onBytes != nil: h.onBytes(e, a, a.up, a.down)
  a.totUp = a.totUp + a.up
  a.totDown = a.totDown + a.down
  a.up = 0
  a.down = 0

proc lastDest*(a: ptr Assoc): EndpointView =
  ## Borrow the last destination inside serialized engine callbacks. Valid until the
  ## next datagram changes its route or the association ends.
  if a.lastDomain:
    result = EndpointView(kind: epName, port: a.dPort, len: a.dLen,
                          data: cast[ptr UncheckedArray[byte]](addr a.dHost[0]))
  else:
    result = EndpointView(kind: a.ipKind, port: a.ipPort,
                          len: (if a.ipKind == epIp4: 4 elif a.ipKind == epIp6: 16 else: 0),
                          data: cast[ptr UncheckedArray[byte]](addr a.ipKey[0]))

proc closePx(e: ptr DatagramEngine; a: ptr Assoc) =
  if a.pxFd >= 0:
    closeEngineFd(e, a.pxFd)
    a.pxFd = -1
  if a.pxCtl >= 0:
    closeEngineFd(e, a.pxCtl)
    a.pxCtl = -1
  let job = a.pxJob
  if job != nil:
    releaseJob(addr job.job)   # ours; the delivered one comes to the inbox
    a.pxJob = nil
  let pend = a.pxPend
  if pend != nil:
    dealloc(pend)
    a.pxPend = nil
    a.pxPendLen = 0
  a.pxReady = false
  let st = a.pxState
  if st != nil:
    let k = a.pxKind
    if k != nil:
      let free = k.legFree
      if free != nil: free(st)
    dealloc(st)
    a.pxState = nil
  a.pxKind = nil

proc dropAssoc*(e: ptr DatagramEngine; slot: int; why = EndError) =
  ## End an association: the end hook, its codec state, sockets, lookup
  ## and owner.
  if not isLive(e.idx, slot): return
  let a = addr e.assocs[slot]
  flushBytes(e, a)   # before the end hook, which may release the owner
  let h = e.hooks
  if h != nil:
    let onEnd = h.onEnd
    if onEnd != nil: onEnd(e, a, why)
  let k = a.kind
  if k != nil:
    let free = k.freeAssoc
    if free != nil: free(a)
  if a.legFd >= 0:
    closeEngineFd(e, a.legFd)
  closePx(e, a)
  let req = a.dnsReq
  if req != nil:
    releaseJob(addr req.job)   # ours; the delivered one comes to the inbox
  let pend = a.pend
  if pend != nil: dealloc(pend)
  a.owner = nil
  resetAssoc(a)
  release(e.idx, slot)
  atomicStore(e.live, e.idx.count, moRelaxed)

proc lookupAssoc*(e: ptr DatagramEngine; ib: int; id: uint64): int =
  ## The live association `id` of listener slot `ib`, or -1. One its codec
  ## no longer serves (the listener changed type in a reload) is dropped.
  result = lookup(e.idx, mixId(id, ib))
  if result >= 0 and e.assocs[result].kind != e.listeners[ib].kind:
    dropAssoc(e, result, EndRemoved)
    result = -1

proc claimAssoc*(e: ptr DatagramEngine; ib: int; id: uint64; now: int64): int =
  ## A new association `id` (not live) on listener slot `ib`, or -1 at the
  ## limit. Pointers into the association table do not survive this call.
  result = claim(e.idx, mixId(id, ib))
  if result < 0: return
  growRecords(e)
  let a = addr e.assocs[result]
  resetAssoc(a)
  e.seq = e.seq + 1
  a.id = (31'u64 shl 48) or (e.seq and 0xFFFF_FFFF_FFFF'u64)
  a.startMono = int64(monoNow())
  a.inTag = e.listeners[ib].tagId
  a.outTag = -1
  a.inb = ib
  a.kind = e.listeners[ib].kind
  a.lastUnix = now
  atomicStore(e.live, e.idx.count, moRelaxed)

proc setPeer*(a: ptr Assoc; peer: ptr SockaddrStorage; peerLen: cuint) {.inline.} =
  copyMem(addr a.peer.ss, peer, int(peerLen))
  a.peer.len = peerLen

proc peerKey*(peer: ptr SockaddrStorage; peerLen: cuint): uint64 =
  ## A 64-bit key of a client address (family, address, port), for codecs
  ## that find associations by client address.
  let raw = cast[ptr UncheckedArray[byte]](peer)
  var h = 0xcbf29ce484222325'u64
  var lo = 0
  var hi = 0
  if cint(peer.ss_family) == AF_INET and peerLen >= 8:
    lo = 2
    hi = 8
  elif cint(peer.ss_family) == AF_INET6 and peerLen >= 24:
    lo = 2
    hi = 24
  var i = lo
  while i < hi:
    if i < 4 or i >= 8 or cint(peer.ss_family) == AF_INET:   # skip the IPv6 flow label
      h = (h xor uint64(raw[i])) * 0x100000001b3'u64
    i = i + 1
  h = h xor uint64(peer.ss_family)
  result = (h xor (h shr 29)) * 0xbf58476d1ce4e5b9'u64

proc samePeer*(a: ptr Assoc; peer: ptr SockaddrStorage; peerLen: cuint): bool =
  ## The association's client address is `peer` (family, address, port).
  if a.peer.len != peerLen or a.peer.ss.ss_family != peer.ss_family: return false
  let x = cast[ptr UncheckedArray[byte]](addr a.peer.ss)
  let y = cast[ptr UncheckedArray[byte]](peer)
  let fam = cint(peer.ss_family)
  var i = 2
  let hi = if fam == AF_INET: 8 elif fam == AF_INET6: 24 else: int(peerLen)
  while i < hi:
    if (fam != AF_INET6 or i < 4 or i >= 8) and x[i] != y[i]: return false
    i = i + 1
  result = true

proc liveAssocs*(e: ptr DatagramEngine): int {.inline.} = atomicLoad(e.live, moRelaxed)

# ------------------------------------------------------------ destinations

