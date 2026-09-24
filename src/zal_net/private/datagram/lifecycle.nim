## Included by datagram/engine; lifecycle.
proc dispatchSocket(e: ptr DatagramEngine; tag: uint64; inB, legB: var MmsgBatch; now: int64) =
  if tag >= CtlBase:
    let slot = int(tag - CtlBase)
    if isLive(e.idx, slot) and e.assocs[slot].pxCtl >= 0: ctlReady(e, slot)
  elif tag >= PxBase:
    let slot = int(tag - PxBase)
    if isLive(e.idx, slot) and e.assocs[slot].pxFd >= 0: pxReady(e, slot, legB, now)
  elif tag >= LegBase:
    let slot = int(tag - LegBase)
    if isLive(e.idx, slot) and e.assocs[slot].legFd >= 0: legReady(e, slot, legB, now)
  elif int(tag) < e.listeners.len and e.listeners[int(tag)].used:
    inboundReady(e, int(tag), inB, now)

proc refreshEngine(e: ptr DatagramEngine; now: int64; lastTick: var int64) =
  let h = e.hooks
  if h != nil and h.refresh != nil: h.refresh(e)
  if now != lastTick:
    tick(e, now)
    lastTick = now

proc runEngine(e: ptr DatagramEngine; inB, legB: var MmsgBatch) {.passive.} =
  let ready = readiness(e)
  if not watchEngine(e, inboxFd(e.inbox[]), WakeTag): return
  var lastTick = 0'i64
  while e.running and not stopping():
    var event = takeReady(ready)
    if event.registration == nil: event = nextReady(ready, afterMs(1000))
    let now = unixSec()
    refreshEngine(e, now, lastTick)
    let registration = event.registration
    if registration != nil and active(registration):
      if event.tag == WakeTag: drainInbox(e, now)
      else: dispatchSocket(e, event.tag, inB, legB, now)
      acknowledge(registration)
    if e.retired.len != 0: drainRetired(e)
proc shutdownEngine(e: ptr DatagramEngine) =
  var i = 0
  while i < e.assocs.len:
    dropAssoc(e, i, EndStop)
    i = i + 1
  i = 0
  while i < e.listeners.len:
    if e.listeners[i].used: removeInbound(e, i)
    i = i + 1
  forgetPx(e)
  # Detach now. Jobs retain only the inbox state and their own inputs/results.
  let h = e.hooks
  if h != nil:
    let onStop = h.onStop
    if onStop != nil: onStop(e)
  e.assocs = @[]
  e.idx = default(AssocIndex)
  e.px = @[]
  e.listeners = @[]

template engineBody(e: ptr DatagramEngine) =
  var family: cint = 0
  let probe = openUdpSocket(family)
  if probe >= 0: discard closeRaw(probe)
  e.legFamily = if probe >= 0: family else: AF_INET6
  let initial = min(InitialAssocs, e.assocLimit)
  initAssoc(e.idx, initial, e.assocLimit)
  e.assocs = newSeq[Assoc](initial)
  e.listeners = newSeq[Listener](e.listenerLimit)
  var i = 0
  while i < e.listeners.len:
    e.listeners[i].fd = -1
    i = i + 1
  i = 0
  while i < initial:
    e.assocs[i].legFd = -1
    e.assocs[i].pxFd = -1
    e.assocs[i].pxCtl = -1
    i = i + 1
  var inB = default(MmsgBatch)
  var outB = default(MmsgBatch)
  var legB = default(MmsgBatch)
  # Without its batches and runs (anonymous mappings) the engine does not
  # run: every send path writes into them.
  if initBatch(inB, e.batch, recvCtrl = true) and initBatch(outB, e.batch) and
     initBatch(legB, e.batch, recvCtrl = true) and initRun(e.reply) and initRun(e.fwd):
    initGsoOut(e.tx, addr outB)
    runEngine(e, inB, legB)
  shutdownEngine(e)
  let pending = retireAll(readiness(e))
  for registration in pending: join(registration)
  drainRetired(e)
  discardReady(readiness(e))
  closeJobInbox(e.inbox[])
  freeBatch(inB)
  freeBatch(outB)
  freeBatch(legB)
  freeRun(e.reply)
  freeRun(e.fwd)
  atomicStore(e.stopped, 1, moRelease)

# ---------------------------------------------------------------------- API


proc engineMain(e: ptr DatagramEngine) {.passive.} = engineBody(e)
