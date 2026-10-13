import zal_net/private/runtime
## In-memory waits: Notify (permits), Event (manual reset), Oneshot (one
## result from any thread) and Chan (bounded, fixed-size elements, many
## producers and consumers). Notifying, setting, fulfilling, sending and
## closing work from any thread; the waits are passive and run on a loop.
## Every wait takes a deadline (`never` must be written out) and an optional
## cancel token.

import std/atomics
import std/syncio
import std/ticketlocks
import zal_net/rt
import zal_net/rt/cancel
import zal_net/plain
import zal_net/private/sharedmem
import zal_net/private/core/waitq
import zal_net/private/core/park
export WaitResult, cancel

proc resumeList(w: nil ptr WaitNode) =
  ## Resume a list of claimed nodes; each link is read before its waiter can run.
  var n = w
  while n != nil:
    let next = n.qnext
    n.qnext = nil
    beResumeNode(n)
    n = next

# ------------------------------------------------------------------ Notify

type
  Notify* = object
    ## Embed in an object that outlives every waiter.
    lock: TicketLock
    q: WaitQueue
    permits: int

proc notifyOne*(n: ptr Notify; coalesce = false) {.sync.} =
  ## Wake the longest waiter, or store a permit for the next `wait`.
  ## `coalesce` keeps at most one stored permit, for conditions callers recheck.
  {.cast(assumeSync).}:
    acquire(n.lock)
    let w = claimFirst(n.q, wrReady)
    if w == nil:
      if coalesce: n.permits = max(n.permits, 1)
      else: n.permits = n.permits + 1
    release(n.lock)
    if w != nil: beResumeNode(w)

proc notifyAll*(n: ptr Notify) {.sync.} =
  {.cast(assumeSync).}:
    ## Wake every current waiter; stores no permit.
    acquire(n.lock)
    let w = claimAll(n.q, wrReady)
    release(n.lock)
    resumeList(w)

proc takePermit(n: ptr Notify): bool {.inline.} =
  result = false
  if n.permits > 0:
    n.permits = n.permits - 1
    result = true

proc wait*(n: ptr Notify; d: Deadline; tok: nil CancelToken = nil): WaitResult {.passive, sync.} =
  {.cast(assumeSync).}:
    if cancelled(tok): return wrCancelled
    acquire(n.lock)
    let got = takePermit(n)
    release(n.lock)
    if got: return wrReady
    var node = default(WaitNode)
    parkOn(node, addr n.lock, addr n.q, tok, d, n.permits > 0, takePermit(n))
    result = WaitResult(node.res)

# ------------------------------------------------------------------- Event

type
  Event* = object
    ## Manual reset: set until cleared. Embed in a longer-lived object.
    lock: TicketLock
    q: WaitQueue
    fired: bool

proc setEvent*(e: ptr Event) {.sync.} =
  {.cast(assumeSync).}:
    acquire(e.lock)
    e.fired = true
    let w = claimAll(e.q, wrReady)
    release(e.lock)
    resumeList(w)

proc clearEvent*(e: ptr Event) {.sync.} =
  {.cast(assumeSync).}:
    acquire(e.lock)
    e.fired = false
    release(e.lock)

proc isSet*(e: ptr Event): bool {.sync.} =
  {.cast(assumeSync).}:
    acquire(e.lock)
    result = e.fired
    release(e.lock)

proc wait*(e: ptr Event; d: Deadline; tok: nil CancelToken = nil): WaitResult {.passive, sync.} =
  {.cast(assumeSync).}:
    if cancelled(tok): return wrCancelled
    if isSet(e): return wrReady
    var node = default(WaitNode)
    parkOn(node, addr e.lock, addr e.q, tok, d, e.fired)
    result = WaitResult(node.res)

# ----------------------------------------------------------------- Oneshot

type
  OneshotObj = object
    lock: TicketLock
    q: WaitQueue
    refs: int       # atomic; producer + consumer
    state: int      # 0 empty, 1 fulfilled, 2 abandoned
    size: int
  Oneshot* = ptr OneshotObj
    ## One result, written by a producer on any thread and awaited by one
    ## consumer. The payload follows the header in the same allocation.

proc newOneshot*(payloadSize: int): Oneshot =
  ## Two references: the producer's and the consumer's.
  if payloadSize < 0 or payloadSize > high(int) - sizeof(OneshotObj):
    quit "zal-net: invalid oneshot payload size"
  result = cast[Oneshot](requireShared(sizeof(OneshotObj) + payloadSize))
  result.refs = 2
  result.size = payloadSize

proc payload*(o: Oneshot): pointer {.inline.} =
  cast[pointer](cast[int](o) + sizeof(OneshotObj))

proc release*(o: Oneshot) =
  if o != nil and atomicFetchSub(o.refs, 1, moAcquireRelease) == 1: freeShared(o)

proc retain*(o: Oneshot) =
  discard atomicFetchAdd(o.refs, 1, moRelaxed)

proc publish*(o: Oneshot; source: pointer; size: int): bool =
  ## Claim and copy atomically. Competing/repeated producers cannot overwrite
  ## a committed payload; abandoned consumers reject before touching it.
  acquire(o.lock)
  if o.state != 0 or size != o.size:
    release(o.lock)
    return false
  copyMem(payload(o), source, size)
  o.state = 1
  let w = claimFirst(o.q, wrReady)
  release(o.lock)
  if w != nil: beResumeNode(w)
  result = true

proc fulfil*(o: Oneshot): bool =
  ## After writing the payload. False when the consumer abandoned it.
  acquire(o.lock)
  if o.state != 0:
    release(o.lock)
    return false
  o.state = 1
  let w = claimFirst(o.q, wrReady)
  release(o.lock)
  if w != nil: beResumeNode(w)
  result = true

proc abandon*(o: Oneshot) =
  ## The consumer gave up; a later `fulfil` returns false.
  acquire(o.lock)
  if o.state == 0: o.state = 2
  let w = claimAll(o.q, wrClosed)
  release(o.lock)
  resumeList(w)

proc wait*(o: Oneshot; d: Deadline; tok: nil CancelToken = nil): WaitResult {.passive.} =
  if cancelled(tok): return wrCancelled
  acquire(o.lock)
  let state = o.state
  release(o.lock)
  if state == 1: return wrReady
  if state == 2: return wrClosed
  var node = default(WaitNode)
  parkOn(node, addr o.lock, addr o.q, tok, d, o.state != 0)
  result = WaitResult(node.res)
  if result == wrReady:
    acquire(o.lock)
    if o.state == 2: result = wrClosed
    release(o.lock)

# -------------------------------------------------------------------- Chan

type
  ChanObj = object
    lock: TicketLock
    recvq, sendq: WaitQueue
    refs: int       # atomic
    elemSize, cap: int
    head, count: int
    closed: bool
    buf: ptr UncheckedArray[byte]
  Chan* = ptr ChanObj
    ## Bounded FIFO of `elemSize`-byte elements. A wake is a hint: waiters
    ## retry until their deadline, and nothing is handed through a frame.

proc validChanSize*(elemSize, capacity: int): bool {.inline.} =
  ## Checked before allocation; zero and negative dimensions are invalid.
  elemSize > 0 and capacity > 0 and capacity <= high(int) div elemSize

proc newChan*(elemSize, capacity: int): nil Chan =
  ## One reference, the caller's; nil for invalid dimensions/overflow.
  if not validChanSize(elemSize, capacity): return nil
  result = cast[Chan](requireShared(sizeof(ChanObj)))
  result.refs = 1
  result.elemSize = elemSize
  result.cap = capacity
  result.buf = cast[ptr UncheckedArray[byte]](requireShared(result.cap * elemSize))

proc retain*(c: nil Chan) =
  if c != nil: discard atomicFetchAdd(c.refs, 1, moRelaxed)

proc release*(c: nil Chan) =
  if c != nil and atomicFetchSub(c.refs, 1, moAcquireRelease) == 1:
    freeShared(c.buf)
    freeShared(c)

proc trySend*(c: nil Chan; src: pointer): bool =
  ## Copy one element in unless the channel is full or closed.
  if c == nil: return false
  acquire(c.lock)
  if c.closed or c.count == c.cap:
    release(c.lock)
    return false
  let at = (c.head + c.count) mod c.cap
  copyMem(addr c.buf[at * c.elemSize], src, c.elemSize)
  c.count = c.count + 1
  let w = claimFirst(c.recvq, wrReady)
  release(c.lock)
  if w != nil: beResumeNode(w)
  result = true

proc tryRecv*(c: nil Chan; dst: pointer): bool =
  ## Copy one element out unless the channel is empty.
  if c == nil: return false
  acquire(c.lock)
  if c.count == 0:
    release(c.lock)
    return false
  copyMem(dst, addr c.buf[c.head * c.elemSize], c.elemSize)
  c.head = (c.head + 1) mod c.cap
  c.count = c.count - 1
  let w = claimFirst(c.sendq, wrReady)
  release(c.lock)
  if w != nil: beResumeNode(w)
  result = true

proc isClosed(c: nil Chan): bool =
  if c == nil: return true
  acquire(c.lock)
  result = c.closed
  release(c.lock)

proc close*(c: nil Chan) =
  ## Senders get wrClosed from now on; receivers drain what is left first.
  if c == nil: return
  acquire(c.lock)
  c.closed = true
  let r = claimAll(c.recvq, wrReady)
  let s = claimAll(c.sendq, wrReady)
  release(c.lock)
  resumeList(r)
  resumeList(s)

proc send*(c: nil Chan; src: pointer; d: Deadline; tok: nil CancelToken = nil): WaitResult {.passive.} =
  if c == nil: return wrClosed
  result = wrReady
  while true:
    if cancelled(tok): return wrCancelled
    if trySend(c, src): return wrReady
    if isClosed(c): return wrClosed
    var node = default(WaitNode)
    parkOn(node, addr c.lock, addr c.sendq, tok, d, c.closed or c.count < c.cap)
    let r = WaitResult(node.res)
    if r != wrReady: return r

proc recv*(c: nil Chan; dst: pointer; d: Deadline; tok: nil CancelToken = nil): WaitResult {.passive.} =
  if c == nil: return wrClosed
  result = wrReady
  while true:
    if cancelled(tok): return wrCancelled
    if tryRecv(c, dst): return wrReady
    if isClosed(c): return wrClosed
    var node = default(WaitNode)
    parkOn(node, addr c.lock, addr c.recvq, tok, d, c.closed or c.count > 0)
    let r = WaitResult(node.res)
    if r != wrReady: return r

# ----------------------------------------------------------- typed wrappers

type
  Channel*[T] = object
    ## A `Chan` of `T` values. `T` is copied bytewise between threads, so it
    ## must be plain data: no string, seq, ref or nested managed fields,
    ## and pointers only to memory that outlives the
    ## receiver's use.
    raw*: nil Chan

  Promise*[T] = object
    ## A `Oneshot` carrying one `T` (plain data, as for `Channel`).
    raw*: Oneshot

  Received*[T] = object
    ## What a typed wait returns: `value` is set when `res` is wrReady.
    res*: WaitResult
    value*: T

proc newChannel*[T](capacity: int): Channel[T] =
  ## One reference, the caller's (`retain` for each other owner).
  requirePlainData(T)
  result = Channel[T](raw: newChan(sizeof(T), capacity))

proc retain*[T](c: Channel[T]) = retain(c.raw)
proc release*[T](c: Channel[T]) = release(c.raw)
proc close*[T](c: Channel[T]) = close(c.raw)
  ## Senders get wrClosed from now on; receivers drain what is left first.

proc trySend*[T](c: Channel[T]; v: T): bool =
  requirePlainData(T)
  var x = v
  result = trySend(c.raw, addr x)

proc tryRecv*[T](c: Channel[T]; v: var T): bool =
  requirePlainData(T)
  result = tryRecv(c.raw, addr v)

proc send*[T](c: Channel[T]; v: T; d: Deadline; tok: nil CancelToken = nil): WaitResult {.passive.} =
  ## Parks while the channel is full.
  requirePlainData(T)
  var x = v
  result = send(c.raw, addr x, d, tok)

proc recv*[T](c: Channel[T]; d: Deadline; tok: nil CancelToken = nil): Received[T] {.passive.} =
  ## The next value, parking while the channel is empty; wrClosed once it is
  ## closed and drained.
  requirePlainData(T)
  result = default(Received[T])
  result.res = recv(c.raw, addr result.value, d, tok)

proc newPromise*[T](): Promise[T] =
  ## Two references: the producer's and the consumer's; each `release`s.
  requirePlainData(T)
  result = Promise[T](raw: newOneshot(sizeof(T)))

proc fulfil*[T](p: Promise[T]; v: T): bool =
  ## Any thread. False when the consumer abandoned it.
  requirePlainData(T)
  var x = v
  result = publish(p.raw, addr x, sizeof(T))

proc abandon*[T](p: Promise[T]) = abandon(p.raw)
proc release*[T](p: Promise[T]) = release(p.raw)

proc wait*[T](p: Promise[T]; d: Deadline; tok: nil CancelToken = nil): Received[T] {.passive.} =
  requirePlainData(T)
  result = default(Received[T])
  result.res = wait(p.raw, d, tok)
  if result.res == wrReady: copyMem(addr result.value, payload(p.raw), sizeof(T))
