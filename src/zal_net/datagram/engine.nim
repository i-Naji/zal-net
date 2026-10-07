import zal_net/net/endpointdial
## The datagram engine serializes callbacks and association state. The standard
## runtime runs it as a passive pool task with retained readiness registrations.
## Client datagrams are decoded in place by the
## listener's codec (types.nim), routed per destination by the route hook,
## and sent from a socket owned by the association (a direct leg), in GSO
## runs where the kernel has them. Replies are sealed by the same codec and
## go back in runs, or in one sendmmsg for many clients.
##
## Packet processing reuses batch buffers. An association caches its last
## IP destination (route and socket address) and its last domain (route and
## address, resolved on the blocking pool and delivered to the engine's
## inbox; datagrams wait in a bounded queue meanwhile).
##
## A route to a framed leg goes through the association's own socket to the
## leg table entry's server, with the leg kind's framing. The servers'
## addresses are resolved when the provider sets the leg table (and
## refreshed); a leg survives reloads that keep its entry (same key and
## kind), like a TCP connection keeps its upstream. A leg with a setup
## (SOCKS5 UDP ASSOCIATE) is handshaken on the blocking pool; its datagrams
## wait framed until the relay address arrives, and the leg ends with its
## control connection.
##
## Other threads talk to the engine with messages (`postEngineMsg`): add
## or remove a listener, run a proc in serialized engine callbacks, stop. Every
## second the engine expires idle associations, ends those whose owner is
## no longer alive, and reports the payload bytes it carried (`onBytes`).

import std/[atomics, syncio]
import zal_net/rt
import zal_net/private/sys/posix
import zal_net/private/sys/threads
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/raw/mmsg
import zal_net/net/batching
import zal_net/net/dns
import zal_net/raw/io
import zal_net/rt/blocking
import zal_net/net/endpoint
import zal_net/private/datagram/index
import zal_net/raw/gso
import zal_net/private/sys/sock
import zal_net/storage
include zal_net/private/datagram/contracts

const
  InitialAssocs = 1024
  MaxAssocs* = 1 shl 16
  DnsCacheSec = 60
  DnsFailSec = 10
  PendCap = 65536 + 4096      # bytes queued per association during a lookup
  WakeTag = high(uint64)      # poller tag of the inbox
  LegBase = 1'u64 shl 32      # poller tags of direct sockets: LegBase + slot
  PxBase = 2'u64 shl 32       # poller tags of proxy legs: PxBase + slot
  CtlBase = 3'u64 shl 32      # poller tags of legs' control connections
  MsgTag* = high(uint64)      ## job tag of messages (lookups carry a slot)
  PxTag = 1'u64 shl 40        # job tag of server lookups: PxTag + leg table index
  SetupTag = 2'u64 shl 40     # job tag of leg setups: SetupTag + slot

  DnsNone = 0
  DnsOk = 1
  DnsFailed = 2
  DnsPending = 3

  MsgAdd* = 1
  MsgRemove* = 2
  MsgStop* = 3
  MsgCall* = 4

type
  EngineMsg* = object
    ## A message to the engine. Custom messages (MsgCall) embed it as their
    ## first field and allocate with `newEngineMsg(size)`.
    job*: Job
    op*: int
    id*: int
    fd*: cint
    codec*: nil ptr ListenerCodec ## MsgAdd: the listener's codec (nil: ask the provider)
    settings*: nil pointer
    tag*: int32
    ok*: bool
    call*: nil proc (e: ptr DatagramEngine; m: ptr EngineMsg) {.nimcall.}   ## MsgCall
    done: int                 # atomic: handled

proc cCalloc(n, size: csize_t): nil pointer {.importc: "calloc", header: "<stdlib.h>".}
proc cFree(p: nil pointer) {.importc: "free", header: "<stdlib.h>".}
proc cTime(tloc: nil pointer): int64 {.importc: "time", header: "<time.h>".}

proc unixSec*(): int64 {.inline.} = cTime(nil)

proc readiness(e: ptr DatagramEngine): Readiness =
  let ready = e.readiness
  if ready == nil: quit "uninitialized engine readiness"
  result = ready

proc watchEngine(e: ptr DatagramEngine; fd: cint; tag: uint64): bool =
  result = watch(readiness(e), fd, tag)
proc closeEngineFd(e: ptr DatagramEngine; fd: cint) =
  let registration = retire(readiness(e), fd)
  if registration != nil: e.retired.add registration
  else: discard closeRaw(fd)
proc drainRetired(e: ptr DatagramEngine) {.passive.} =
  for registration in e.retired:
    join(registration)
    discard closeRaw(descriptor(registration))
  e.retired = @[]

# ------------------------------------------------------------- associations

include zal_net/private/datagram/associations
include zal_net/private/datagram/legs
include zal_net/private/datagram/resolution
include zal_net/private/datagram/dispatch
include zal_net/private/datagram/control
include zal_net/private/datagram/lifecycle

proc newDatagramEngine*(natSec = 300; batch = 64; hooks: nil ptr EngineHooks = nil;
                        listenerLimit = MaxEngineListeners; maxAssocs = MaxAssocs;
                        pendingBytes = PendCap; controlLimit = 4096; provider: nil pointer = nil; adaptiveBatching = true): nil ptr DatagramEngine =
  ## An engine, not yet running; nil when its poller or inbox cannot be
  ## made. C memory: it is retained until the engine stops. `hooks` (may be
  ## nil) route and account for its associations.
  result = nil
  if listenerLimit < 1 or listenerLimit > (1 shl 20) or maxAssocs < 1 or
     maxAssocs > (1 shl 24) or (maxAssocs and (maxAssocs - 1)) != 0 or
     controlLimit < 1 or pendingBytes < 2 or pendingBytes > (1 shl 30) or batch < 1 or batch > 1024:
    return
  # The blocking pool delivers lookups into the inbox: it outlives the
  # engine unless every lookup came back.
  let mem = cCalloc(1, csize_t(sizeof(DatagramEngine)))
  let box = cCalloc(1, csize_t(sizeof(JobInbox)))
  if mem == nil or box == nil:
    cFree(mem)
    cFree(box)
    return
  let e = cast[ptr DatagramEngine](mem)
  e.inbox = cast[ptr JobInbox](box)
  e.listenerLimit = listenerLimit
  e.assocLimit = maxAssocs
  e.pendingCap = pendingBytes
  e.controlLimit = controlLimit
  e.provider = provider
  e.natSec = max(1, natSec)
  e.batch = batch
  e.adaptiveBatching = adaptiveBatching
  e.inBudget = initReceiveBudget(batch)
  e.legBudget = initReceiveBudget(batch)
  e.running = true
  e.hooks = hooks
  e.routeGen = 1
  if not initJobInbox(e.inbox[]):
    cFree(box)
    cFree(mem)
    return
  e.readiness = newReadiness()
  result = e

proc startEngine*(e: ptr DatagramEngine) =
  var expected = 0
  if not atomicCompareExchange(e.started, expected, 1, moAcquireRelease, moAcquire): return
  if not trySpawnTask(engineMain(e)):
    closeJobInbox(e.inbox[])
    atomicStore(e.stopped, 1, moRelease)
proc noJob(j: ptr Job) {.nimcall.} = discard

proc discardMessage(j: JobPtr) {.nimcall.} =
  let message = cast[ptr EngineMsg](j)
  if message.op == MsgAdd and message.fd >= 0:
    discard closeRaw(message.fd)
    message.fd = -1
  message.ok = false
  atomicStore(message.done, 1, moRelease)

proc newEngineMsg*(op: int; size = sizeof(EngineMsg)): ptr EngineMsg =
  result = cast[ptr EngineMsg](newJob(max(size, sizeof(EngineMsg)), noJob, onDrop = discardMessage))
  result.op = op
  result.fd = -1

proc postEngineMsg*(e: ptr DatagramEngine; m: ptr EngineMsg) =
  ## Deliver `m`; the caller keeps its reference (`releaseEngineMsg`).
  m.job.tag = MsgTag
  # Stop must remain deliverable when ordinary control admission is full.
  let limit = if m.op == MsgStop: 0 else: e.controlLimit
  if not postJob(e.inbox, addr m.job, maxQueued = limit): discardMessage(addr m.job)

proc engineMsgDone*(m: ptr EngineMsg): bool {.inline.} = atomicLoad(m.done, moAcquire) != 0

proc releaseEngineMsg*(m: ptr EngineMsg) {.inline.} = releaseJob(addr m.job)

proc addListener*(e: ptr DatagramEngine; id: int; fd: cint; codec: nil ptr ListenerCodec = nil;
                  settings: nil pointer = nil; tagId = -1'i32): ptr EngineMsg =
  ## Serve listener `id` on the UDP socket `fd`, which the engine now owns
  ## (and closes if it cannot take it: `ok` is false once done), with
  ## `codec` and its `settings`; without a codec, the `listenerAdded` hook
  ## binds it.
  result = newEngineMsg(MsgAdd)
  result.id = id
  result.fd = fd
  result.codec = codec
  result.settings = settings
  result.tag = tagId
  postEngineMsg(e, result)

proc removeListener*(e: ptr DatagramEngine; id: int): ptr EngineMsg =
  ## Close listener `id` and end its associations; its port is free once
  ## the message is done.
  result = newEngineMsg(MsgRemove)
  result.id = id
  postEngineMsg(e, result)

proc stopEngine*(e: ptr DatagramEngine): ptr EngineMsg =
  result = newEngineMsg(MsgStop)
  postEngineMsg(e, result)

proc engineStopped*(e: ptr DatagramEngine): bool {.inline.} = atomicLoad(e.stopped, moAcquire) != 0

proc waitEngineMsg*(m: ptr EngineMsg; timeoutMs: int): bool =
  ## Block this thread until `m` is handled (not on a loop: use a passive
  ## wait there).
  var waited = 0
  while not engineMsgDone(m) and waited < timeoutMs:
    sleepUs(1000)
    waited = waited + 1
  result = engineMsgDone(m)

proc freeEngine*(e: ptr DatagramEngine): bool =
  ## Consume the engine after its worker stopped, or before it was started.
  ## False leaves ownership with the caller; retry after `engineStopped`.
  ## On true the pointer is invalid. No producer may still access the handle.
  if atomicLoad(e.started, moAcquire) != 0:
    if not engineStopped(e): return false
  else:
    discard
  closeJobInbox(e.inbox[])
  cFree(e.inbox)
  # The engine is C memory: its seqs are destroyed here, by hand, before
  # the block goes.
  e.assocs = @[]
  e.px = @[]
  e.retired = @[]
  e.readiness = nil
  cFree(e)
  result = true

# -------------------------------------------------------- the tunnel codec
# Each client address is an association whose datagrams go to the
# listener's fixed target (its settings: a TunnelTarget); replies come back
# bare.

proc tunnelOpen(e: ptr DatagramEngine; ib: int; p: ptr UncheckedArray[byte]; n: int;
                peer: ptr SockaddrStorage; peerLen: cuint; now: int64;
                pkt: var Packet): bool =
  let ts = cast[ptr TunnelTarget](e.listeners[ib].settings)
  if ts == nil or not valid(ts.destination): return false
  let id = peerKey(peer, peerLen)
  var slot = lookupAssoc(e, ib, id)
  # A key collision: the client that came first keeps the association.
  if slot >= 0 and not samePeer(assocAt(e, slot), peer, peerLen): return false
  if slot < 0:
    slot = claimAssoc(e, ib, id, now)
    if slot < 0: return false
    setPeer(assocAt(e, slot), peer, peerLen)
  pkt.slot = slot
  pkt.dst = endpointView(ts.destination)
  pkt.pay = p
  pkt.payLen = n
  result = true

proc tunnelReply(e: ptr DatagramEngine; slot: int; src: EndpointView;
                 pay: ptr UncheckedArray[byte]; payLen: int; outp: ptr UncheckedArray[byte]; outCap: int;
                 now: int64): int =
  if payLen > 0: copyMem(addr outp[0], addr pay[0], payLen)
  result = payLen

let tunnelCodec* = ListenerCodec(open: tunnelOpen, sealReply: tunnelReply, replyOverhead: 0)

# ----------------------------------------------------------------- listing

type
  AssocInfo* = object
    ## A copy of a live association, for listings.
    id*: uint64
    startMono*: int64
    inTag*, outTag*: int32
    up*, down*: int64
    dsts*: int32
    userLen*: int
    user*: array[MaxOwnerName, char]
    src*, dst*: Endpoint

  ListMsg = object
    ## The job owns its trailing result storage. Caller and inbox references
    ## keep it alive through timeout, rejection, and late completion.
    msg: EngineMsg
    cap, n, total: int
    items: array[1, AssocInfo]
  ListMsgPtr = ptr ListMsg

proc listItems(m: ListMsgPtr): ptr UncheckedArray[AssocInfo] {.inline.} =
  ## The allocation extends the typed first element to m.cap entries.
  cast[ptr UncheckedArray[AssocInfo]](addr m.items[0])

proc listCall(e: ptr DatagramEngine; m: ptr EngineMsg)

proc newListMsg(capacity: int): nil ListMsgPtr =
  if capacity < 1 or
     capacity - 1 > (high(int) - sizeof(ListMsg)) div sizeof(AssocInfo):
    return nil
  let size = sizeof(ListMsg) + (capacity - 1) * sizeof(AssocInfo)
  result = cast[ListMsgPtr](newEngineMsg(MsgCall, size))
  result.cap = capacity
  result.msg.call = listCall

proc listCall(e: ptr DatagramEngine; m: ptr EngineMsg) =
  ## In an engine callback: copy live associations into the message.
  let lm = cast[ListMsgPtr](m)
  let items = listItems(lm)
  lm.total = e.idx.count
  var i = 0
  while i < e.assocs.len and lm.n < lm.cap:
    if isLive(e.idx, i):
      let a = addr e.assocs[i]
      let it = addr items[lm.n]
      it.id = a.id
      it.startMono = a.startMono
      it.inTag = a.inTag
      it.outTag = a.outTag
      it.up = a.totUp + a.up
      it.down = a.totDown + a.down
      it.dsts = a.dsts
      it.userLen = 0
      let h = e.hooks
      if a.owner != nil and h != nil and h.ownerName != nil:
        let size = h.ownerName(a, cast[ptr UncheckedArray[char]](addr it.user[0]), MaxOwnerName)
        if size >= 0 and size <= MaxOwnerName: it.userLen = size
      discard toEndpoint(socketEndpointView(addr a.peer.ss, a.peer.len), it.src)
      discard toEndpoint(lastDest(a), it.dst)
      lm.n = lm.n + 1
    i = i + 1
  m.ok = true

proc listAssocs*(e: ptr DatagramEngine; outp: ptr seq[AssocInfo]; limit: int): int {.passive.} =
  ## Append up to min(limit, engine association limit) live snapshots to outp[].
  ## Return the total live count, or -1 on invalid input, rejected delivery or
  ## a one-second timeout. Failure leaves outp[] unchanged. A late engine reply
  ## writes only to message-owned storage, which final job release frees.
  result = -1
  if e == nil or limit <= 0: return
  let request = newListMsg(min(limit, e.assocLimit))
  if request == nil: return
  let m: ListMsgPtr = request
  postEngineMsg(e, addr m.msg)
  let deadline = afterMs(1000)
  while not engineMsgDone(addr m.msg) and monoNow() < deadline:
    sleepMs(1)
  if engineMsgDone(addr m.msg) and m.msg.ok:
    let items = listItems(m)
    var i = 0
    while i < m.n:
      outp[].add items[i]
      i = i + 1
    result = m.total
  releaseEngineMsg(addr m.msg)

proc inboundBatchTarget*(e: ptr DatagramEngine): int =
  ## Serialized engine callback only. Cross-thread readers use MsgCall.
  if e.adaptiveBatching: target(e.inBudget) else: e.batch
proc legBatchTarget*(e: ptr DatagramEngine): int =
  ## Same serialized-callback contract; direct/proxy replies share this budget.
  if e.adaptiveBatching: target(e.legBudget) else: e.batch
