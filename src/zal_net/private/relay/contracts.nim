## Included by relay/conn; declarations and extension contracts.
const
  MaxRecord* = 65535                     ## the largest record payload a framer may declare
  HeadRoom* = 128                        ## room before the first record in every direction
  Batch* = when defined(nnRelayCompact): 2 else: 4
    ## Maximum records per read/write system call.
    ## Each direction reserves storage for Batch records.
  BufCap* = HeadRoom + Batch * (18 + MaxRecord + 16)
  MaxSpans* = 64
  PreCap* = 64                           ## a sink's control prefix (Dir.pre)
  YieldBytes = 1 shl 20                  # fairness: yield after this many bytes
  PoolMax = 32                           # idle connection blocks kept for reuse
  StateWords* = 16                       ## framer state per Dir side: 128 bytes
  ProtoWords* = 16                       ## the protocol's data per connection: 128 bytes
  ExtWords* = 96                         ## the framework's data per connection: 768 bytes

  InAgain* = 0                           ## ingest/emit: park, then retry
  InFail* = -1
  InEof* = -2                            ## clean end of stream on a record boundary

when Batch < 2:
  {.error: "an incomplete maximal record must fit after compaction".}

type
  Span* = object
    off*: int
    len*: int

  Geometry* = object
    head*, tail*: int      ## bytes around each record's payload on the wire
    maxRecord*: int        ## the largest payload per record (1 .. MaxRecord)
    headRoom*: int
      ## Room needed before the first payload of a stream, that record's
      ## head included (0: just the head): a response header, say.
      ## `max(head, headRoom)` is at most HeadRoom.

  FramerObj* = object
    ## Regular procs, called once per batch. `open` decodes every complete
    ## record in d.buf[d.off ..< d.fill] in place into d.spans (>0 spans,
    ## 0 more bytes needed, InFail); `seal` frames d.spans in place into
    ## one region d.wOff ..< d.wEnd.
    geometry*: Geometry
    open*: proc (c: Conn; d: DirectionPtr): int {.nimcall.}
    sourceEnded*: nil proc (d: DirectionPtr): bool {.nimcall.}
      ## Protocol EOF known without another read; nil when only the transport can end.
    atBoundary*: proc (d: DirectionPtr): bool {.nimcall.}  # may the stream end here
    seal*: proc (c: Conn; d: DirectionPtr): bool {.nimcall.}
    closeSource*: proc (d: DirectionPtr) {.nimcall.}
    closeSink*: proc (d: DirectionPtr) {.nimcall.}
    finish*: nil proc (c: Conn; d: DirectionPtr): bool {.nimcall.}
      ## A sink's end of stream (nil: none): called once when the
      ## direction's source ended cleanly, before the half-close; it may put
      ## a closing record in `d.pre`. False fails the direction.
    readFailed*: nil proc (c: Conn; d: DirectionPtr; err: int): int {.nimcall.}
      ## A source's read failed hard with `err` (errno; nil: the direction
      ## fails). It may read what is pending itself (a kTLS control record
      ## after EIO), even into d.buf at d.fill: InAgain retries (open, then
      ## read), InEof ends cleanly, InFail fails.
    writePrefix*: nil proc (c: Conn; d: DirectionPtr): int {.nimcall.}
      ## A sink that writes `d.pre[d.preAt ..< d.preLen]` itself (nil: one
      ## writev with the region), advancing `preAt`: 1 when all is out,
      ## InAgain to wait until writable and be called again, InFail.

  Framer* = ptr FramerObj  ## nil: plain bytes

  EndReason* = enum
    erEof        ## both directions ended cleanly (or still running)
    erIdle       ## the idle timeout
    erError      ## a read or write failed, or a reset
    erRejected   ## failed before the pumps (`failConn`)

  ConnHooks* = object
    ## A framework's view of its connections; either may be nil.
    onBatch*: nil proc (c: Conn; d: DirectionPtr; bytes: int) {.nimcall.}  ## after each batch
    onEnd*: nil proc (c: Conn) {.nimcall.}   ## once, before the descriptors close

  Dir* = object
    src*, dst*: cint
    srcFramer*, dstFramer*: nil Framer  # nil: plain
    off*, fill*: int        # source window
    nspans*: int
    bytes*: int             # payload bytes in the current batch
    wOff*, wEnd*: int       # framed output progress
    iovAt, iovEnd: int    # writev progress
    slotStride, slotMax, slotCount: int  # a plain source's slots (layout)
    inStride: int          # a framed source's largest wire record (layout)
    srcSt, dstSt: array[StateWords, uint64]  # framer state
    preLen*, preAt*: int    # a framed sink's control prefix: pre[preAt ..< preLen] goes out first
    pre*: array[PreCap, byte]
    relayout: bool         # the sink cannot seal the source's records in place: copy via `alt`
    sinkInAlt: bool        # the sink's state words are in `alt` now (relayout, or a split in progress)
    alt: nil DirectionPtr       # sink-shaped slots and, while in use, the sink's state (pooled, on demand)
    spans*: array[MaxSpans, Span]
    iov: array[MaxSpans, IoVec]
    payload: nil BytesPtr       ## owned stable mapping, absent until first use

  ConnObj* = object
    refs: int              # running pumps (atomic)
    lastIo*: int64          # shared activity stamp (atomic)
    timeoutMs*: int
    payloadIdleMs*: int         ## immutable while pumps run; zero disables idle reclamation
    fd*: cint               # the accepted (inbound) side
    up*: cint               # the outbound side
    poolNext: nil ptr ConnObj
    hooks*: nil ptr ConnHooks   # nil: none
    endReason*: EndReason
    upBytes*, downBytes*: int64        # payload a->b and b->a (relaxed atomics)
    failed: bool                       # a direction failed: both sockets reset, no FIN (atomic)
    proto: array[ProtoWords, uint64]  # protocol data; zeroed on free
    ext: array[ExtWords, uint64]      # framework data; zeroed by newConn
    a*: Dir                 # fd -> up
    b*: Dir                 # up -> fd

  Conn* = ptr ConnObj
  DirectionPtr* = ptr Dir

proc sourceState*[T](d: DirectionPtr): ptr T {.inline.} =
  ## Borrow zero-initialized, eight-byte-aligned framer storage. T must contain
  ## plain data only; the framer's close hook owns cleanup. Do not retain this
  ## pointer beyond the callback: relayout can move the sink state.
  result = storageAs(d.srcSt, T)

proc sinkState*[T](d: DirectionPtr): ptr T {.inline.} =
  ## Same contract as sourceState; valid only during the framer callback.
  result = storageAs(d.dstSt, T)

proc protocolState*[T](c: Conn): ptr T {.inline.} =
  ## Plain protocol state, owned until freeConn. Zeroed before reuse.
  result = storageAs(c.proto, T)

proc extensionState*[T](c: Conn): ptr T {.inline.} =
  ## Plain caller state; the end hook must release any owned resources.
  result = storageAs(c.ext, T)


type PumpFailure = enum
  pfNone, pfSource, pfReadWait, pfFraming, pfSink, pfWriteWait, pfPeer
