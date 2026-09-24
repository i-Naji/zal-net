import zal_net/private/sys/threads
## Types shared by the datagram engine and the code that plugs into it.
##
## A protocol that carries datagrams to clients supplies a `ListenerCodec`,
## run in serialized engine callbacks (regular procs, no parking):
##
## - `open` authenticates and decodes one client datagram in place, finds
##   or creates its association (`lookupAssoc`/`claimAssoc`), keeps the
##   client's address in it, and names the destination (an endpoint view)
##   and the payload;
## - `sealReply` frames a datagram from a destination for the client;
## - `bindListener`/`unbindListener` keep per-listener state (pre-keyed
##   ciphers) for the listener's current settings; `freeAssoc` releases
##   what the codec kept in an association.
##
## Codec state lives in `Listener.cst` and `Assoc.st`. Neither may point
## into data the provider frees on reload: associations outlive it.
## A destination is carried by a leg of some `LegKind`: direct, block, or
## framed. A framed leg is the association's own socket to a server, and
## the kind frames datagrams for it (`legSeal`) and decodes the server's
## (`legRecv`); its state is allocated per leg (`legStateSize` bytes) and
## must not point into reloadable data either. A kind whose leg needs a
## handshake first (SOCKS5 UDP ASSOCIATE) sets `legSetup`: it runs on the
## blocking pool with a copy of the leg's state, and returns the address
## to send to and a control connection that the leg lives with; datagrams
## wait framed meanwhile.
##
## A framework (the provider) routes destinations to legs and accounts for
## associations through `EngineHooks`; without hooks every destination
## goes direct.

import zal_net/net/sockaddr
import zal_net/net/dns
import zal_net/foundation/readiness
import zal_net/rt/blocking
import zal_net/net/endpoint
import zal_net/private/datagram/index
import zal_net/raw/gso

const
  MaxEngineListeners* = 32
  AssocWords* = 32                ## codec state per association: 256 bytes
  LegSetupWords* = 128            ## a leg's state as copied into its setup job
  ListenerWords* = 8              ## codec state per listener
  MaxOwnerName* = 64              ## `EngineHooks.ownerName`'s room

  LegNone* = 0                    ## the destination is not carried: drop
  LegDirect* = 1                  ## send from a socket of the association's own
  LegBlock* = 2                   ## drop
  LegFramed* = 3                  ## through a server, framed (a leg)
  LegResolve* = -1                ## a route's mode: the name's addresses are needed first

  EndError* = 0                   ## why an association ended (EngineHooks.onEnd)
  EndIdle* = 1
  EndKicked* = 2                  ## `alive` said no
  EndRemoved* = 3                 ## its listener went away or changed codec
  EndStop* = 4

type
  Packet* = object
    ## A client datagram, decoded.
    slot*: int                    ## its association
    dst*: EndpointView            ## borrows codec input/settings for this dispatch
    pay*: ptr UncheckedArray[byte]
    payLen*: int

  Listener* = object
    used: bool
    fd: cint
    id*: int                      ## listener id (the caller's)
    label*: int                   ## the provider's index for it, -1: none
    settings*: nil pointer        ## the codec's settings
    kind: nil ptr ListenerCodec  ## nil: datagrams are dropped
    tagId*: int32                 ## the provider's tag for records, -1
    cst: array[ListenerWords, uint64]

  Assoc* = object
    ## One client flow: its address, owner, direct socket and codec state.
    id*: uint64                   ## for records and listings
    startMono*: int64
    inTag*, outTag*: int32        ## the provider's tags: its listener, its last leg
    totUp*, totDown*: int64       ## payload bytes counted so far (flushed)
    dsts*: int32                  ## destination changes
    lastDomain*: bool             ## the last destination was a name
    inb: int                     ## engine listener slot
    kind: unchecked ptr ListenerCodec   ## the codec that created it; set while live
    peer: SockAddrBuf            ## where replies go
    owner*: nil pointer           ## the provider's owner (a user), or nil
    ownerGen*: int                ## the owner's generation when bound (`alive`)
    lastUnix: int64
    up, down: int64             ## payload bytes not yet counted
    legFd: cint                  ## direct socket, opened on first use; -1
    legFamily: cint
    # The framed leg: a socket to one leg table entry's server, and the
    # leg kind's state for it.
    pxFd: cint                   ## -1: none
    pxTag: uint64                ## its entry's key: a reload keeps the leg
                                  ## while the key and kind stay
    pxKind: unchecked ptr LegKind   ## set while pxFd >= 0
    pxAddr: SockAddrBuf
    pxState: nil pointer
    pxReady: bool                ## set up (always, without `legSetup`)
    pxJob: nil ptr LegSetupJob   ## the setup in flight (our reference), or nil
    pxCtl: cint                  ## the setup's control connection, -1
    pxFailUnix: int64            ## when a setup last failed
    pxPend: nil ptr UncheckedArray[byte]   ## framed datagrams waiting for the setup
    pxPendLen: int
    # The last IP destination: its route and socket address.
    ipGen, ipMode, ipOut: int
    ipKind: EndpointKind
    ipPort: uint16
    ipKey: array[16, byte]
    ipAddr: SockAddrBuf
    # The last domain destination: its route, and its address resolved
    # outside engine callbacks (datagrams wait in `pend` meanwhile).
    dGen, dMode, dOut, dLen: int
    dPort: uint16
    dHost: array[255, char]
    dnsState: int
    dnsReq: nil ptr ResolveJob
    cacheAddr: SockAddrBuf
    cacheUnix: int64
    pend: nil ptr UncheckedArray[byte]
    pendLen: int
    st: array[AssocWords, uint64]

  ListenerCodec* = object
    open*: proc (e: ptr DatagramEngine; ib: int; p: ptr UncheckedArray[byte]; n: int;
                 peer: ptr SockaddrStorage; peerLen: cuint; now: int64;
                 pkt: var Packet): bool {.nimcall.}
    sealReply*: proc (e: ptr DatagramEngine; slot: int; src: EndpointView;
                      pay: ptr UncheckedArray[byte]; payLen: int;
                      outp: ptr UncheckedArray[byte]; outCap: int; now: int64): int {.nimcall.}
      ## The reply at `outp`, which has room for payLen +
      ## replyOverhead bytes (at most UdpMax); its length, or 0 to drop.
      ## src borrows address bytes for this callback. replyOverhead includes
      ## every header byte, including any address encoding chosen by the codec.
    replyOverhead*: int
    bindListener*: nil proc (e: ptr DatagramEngine; ib: ptr Listener): bool {.nimcall.}
    unbindListener*: nil proc (ib: ptr Listener) {.nimcall.}
    freeAssoc*: nil proc (a: ptr Assoc) {.nimcall.}

  LegKind* = object
    mode*: int                    ## LegDirect, LegBlock or LegFramed
    # LegFramed only (set exactly when mode == LegFramed):
    legServer*: nil proc (settings: pointer): ptr Endpoint {.nimcall.}
    legOpen*: unchecked proc (st: pointer; settings: pointer): bool {.nimcall.}
      ## Initialize a leg's state (`legStateSize` zeroed bytes).
    legSeal*: unchecked proc (st: pointer; dst: EndpointView;
                    pay: ptr UncheckedArray[byte]; payLen: int;
                    outp: ptr UncheckedArray[byte]; outCap: int; now: int64): int {.nimcall.}
      ## A datagram for the server at `outp` (room for payLen +
      ## legOverhead bytes); its length, or 0.
    legRecv*: unchecked proc (st: pointer; p: ptr UncheckedArray[byte]; n: int; now: int64;
                    src: var EndpointView; payOff, payLen: var int): bool {.nimcall.}
      ## Decode in place. src borrows p or leg-owned storage through dispatch;
      ## payload offsets must remain within p[0 ..< n]. legOverhead includes all
      ## address and protocol header bytes, and bounds legSeal's output.
    legFree*: nil proc (st: pointer) {.nimcall.}   ## nil: nothing to free
    legOverhead*: int
    legStateSize*: int
    legSetup*: nil JobFn          ## nil: none. Runs on the blocking pool with
                                  ## a `ptr LegSetupJob`; regular code

  LegSetupJob* = object
    ## A leg's setup on the blocking pool. It writes only here.
    job*: Job
    server*: SockAddrBuf          ## the leg's server
    family*: cint                 ## the leg's socket family: `relay` must match
    localPort*: uint16            ## the leg's own port
    st*: array[LegSetupWords, uint64]   ## a copy of the leg's state
    ok*: bool                     ## results:
    ctlFd*: cint                  ## the control connection (nonblocking), -1
    relay*: SockAddrBuf           ## where the leg sends

  PxServer = object
    ## A leg table entry: a framed leg kind, its settings, and its server's
    ## address (resolved when the entry is set, and refreshed).
    kind*: nil ptr LegKind        ## nil: an empty entry
    settings*: nil pointer        ## set with `kind`
    key*: uint64                  ## an association's leg survives while this stays
    gen*: int
    state*: int
    sa*: SockAddrBuf
    unix*: int64
    req*: nil ptr ResolveJob

  LegChoice* = object
    ## A route's answer. It starts as direct.
    kind*: nil ptr LegKind        ## nil: the destination is not carried (dropped)
    leg*: int                     ## the leg table index (framed legs), else -1
    tag*: int32                   ## the provider's label for records, -1

  RouteResult* = enum
    rrDone, rrResolve

  EngineHooks* = object
    ## A framework's side of the engine. Every hook runs on the engine
    ## thread and may be nil.
    refresh*: nil proc (e: ptr DatagramEngine) {.nimcall.}
      ## Each wake: rebind listeners and legs after a reload.
    listenerAdded*: nil proc (e: ptr DatagramEngine; slot: int) {.nimcall.}
      ## A listener was added without a codec (`setListenerCodec`).
    route*: nil proc (e: ptr DatagramEngine; a: ptr Assoc; dest: ptr Endpoint; resolved: bool;
                  addrs: ptr UncheckedArray[SockAddrBuf]; nAddrs: int;
                  choice: var LegChoice): RouteResult {.nimcall.}
      ## The leg for `dest`, or rrResolve to have the name looked up
      ## first. `resolved`: `addrs[0 ..< nAddrs]` are the name's addresses
      ## (none when the lookup failed).
    alive*: nil proc (e: ptr DatagramEngine; a: ptr Assoc; owner: pointer): bool {.nimcall.}
      ## May an owned association (`owner`: its owner) go on? Asked per
      ## datagram and per tick.
    onBytes*: nil proc (e: ptr DatagramEngine; a: ptr Assoc; up, down: int64) {.nimcall.}
      ## Payload carried since the last call (each tick and at the end).
    onEnd*: nil proc (e: ptr DatagramEngine; a: ptr Assoc; why: int) {.nimcall.}
      ## An association ends (End*), after its last onBytes: the provider
      ## may release the owner here. Its bytes are totUp and totDown.
    ownerName*: nil proc (a: ptr Assoc; outp: ptr UncheckedArray[char]; cap: int): int {.nimcall.}
      ## Write the owner's name within outp[0 ..< cap]; return its length in
      ## 0..cap. Invalid returned lengths are treated as an empty name.
    onStop*: nil proc (e: ptr DatagramEngine) {.nimcall.}
      ## The engine stops, after every association ended.

  TunnelTarget* = object
    ## The tunnel codec's settings: every datagram goes to one destination.
    destination*: Endpoint       ## owns its destination; no wire format

  DatagramEngine* = object
    readiness: nil Readiness
    retired: seq[Registration]
    inbox: ptr JobInbox
    listeners: seq[Listener]
    listenerLimit, assocLimit, pendingCap, controlLimit: int
    idx: AssocIndex
    assocs: seq[Assoc]
    hooks: nil ptr EngineHooks   ## nil: every destination direct, no owners
    provider: nil pointer        ## the hooks' own data
    routeGen: int                ## bumped to make associations route again (from 1)
    natSec: int
    batch: int
    adaptiveBatching: bool
    inBudget, legBudget: ReceiveBudget
    tx: GsoOut
    fwd, reply: GsoRun
    px: seq[PxServer]            ## the leg table (`setLegs`, `setLeg`)
    legFamily: cint              ## the family of the engine's sockets
    running: bool
    dnsOut: int                  ## lookups submitted and not yet delivered
    live: int                    ## atomic: associations, for other threads
    seq: uint64                  ## association ids
    started: int
    stopped: int                 ## atomic: the thread has finished

# State storage borrows are confined to callbacks inside serialized engine callbacks.
proc listenerState*[T](l: ptr Listener): ptr T {.inline.} =
  result = storageAs(l.cst, T)
proc associationState*[T](a: ptr Assoc): ptr T {.inline.} =
  result = storageAs(a.st, T)
proc providerContext*(e: ptr DatagramEngine): nil pointer {.inline.} = e.provider
proc listenerAt*(e: ptr DatagramEngine; slot: int): nil ptr Listener =
  ## Engine callback only; a listener slot supplied to a codec callback is valid.
  if slot < 0 or slot >= e.listeners.len or not e.listeners[slot].used: return nil
  result = addr e.listeners[slot]
