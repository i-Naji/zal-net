## Retained listener owner. One pending accept is admitted.
## A queued task retaining this owner must use a `sink TcpListenerRef` parameter.
## Accepted connections belong to the caller; closing the listener does not
## close connections already returned. Import explicitly with tcpref.
import zal_net/[rt, errors], zal_net/rt/[sync, cancel], zal_net/raw/io
import zal_net/raw/tcp, zal_net/foundation/tcp, zal_net/ownership
import zal_net/ownership
import std/ticketlocks

export ownership

type
  TcpListenerObj = object
    listener: TcpListener             ## sole, stable raw owner
    life: OwnerLife
    tokenLock: TicketLock
    accepting: nil CancelToken       ## owned child, retained until accept ends
  TcpListenerRef* = ref TcpListenerObj
  TcpListenerResult* = object
    value*: nil TcpListenerRef        ## caller owns on success
    code*: int                       ## zero success; negative error otherwise

proc `=destroy`(owner: var TcpListenerObj) =
  ## Pending operations retain this object. Destruction never blocks.
  closeNow(owner.listener)
  release(owner.accepting)

proc takeTcpListenerRef*(listener: TcpListenerPtr): TcpListenerResult =
  ## Transfer a quiescent listener. No raw accept or serve may still borrow it.
  ## Failure preserves the raw owner.
  result = default(TcpListenerResult)
  if stopping(): return TcpListenerResult(code: ResourceClosed)
  if not listener[].ok: return TcpListenerResult(code: ResourceClosed)
  if listenerClosing(nativeHandle(listener[])):
    return TcpListenerResult(code: ResourceBusy)
  let owner = TcpListenerRef()
  initOwnerLife(owner.life)
  owner.listener = takeTcpListener(listener)
  result.value = owner

proc takeTcpListenerRef*(listener: var TcpListener): TcpListenerResult {.inline.} =
  takeTcpListenerRef(addr listener)

proc listenTcpRef*(port: uint16; host = ""; backlog = 1024; noDelay = true;
                   reusePort = false): TcpListenerResult =
  ## A failed constructor owns no descriptor.
  result = default(TcpListenerResult)
  if stopping(): return TcpListenerResult(code: ResourceClosed)
  let owner = TcpListenerRef()
  result.code = listenInto(addr owner.listener, port, host, backlog, noDelay, reusePort)
  if result.code == 0:
    initOwnerLife(owner.life)
    result.value = owner

proc state*(owner: TcpListenerRef): OwnerState {.inline.} = state(owner.life)
proc cleanup(owner: TcpListenerRef)
proc finishControl(owner: TcpListenerRef) =
  endControl(owner.life)
  cleanup(owner)

proc nativeHandle*(owner: TcpListenerRef): cint =
  if beginControl(owner.life) != 0: return -1
  result = nativeHandle(owner.listener)
  finishControl(owner)
proc port*(owner: TcpListenerRef): uint16 {.inline.} = port(owner.listener)

proc beginAccept(owner: TcpListenerRef; tok: nil CancelToken): int =
  owner.tokenLock.acquire()
  result = beginBorrow(owner.life, false)
  if result == 0:
    # One child per accept operation, never per established I/O iteration.
    # It combines caller cancellation and listener close without shutting down
    # or recycling a descriptor while a poll may still reference it.
    owner.accepting = newCancelToken(tok)

  owner.tokenLock.release()

proc rawListener(owner: TcpListenerRef): TcpListenerPtr {.inline.} = addr owner.listener
proc acceptToken(owner: TcpListenerRef): nil CancelToken {.inline.} = owner.accepting
proc ownerLife(owner: TcpListenerRef): ptr OwnerLife {.inline.} = addr owner.life

proc cleanup(owner: TcpListenerRef) =
  if claimOwnerCleanup(owner.life):
    closeNow(owner.listener)
    markClosed(owner.life)

proc endAccept(owner: TcpListenerRef) =
  owner.tokenLock.acquire()
  release(owner.accepting)
  owner.accepting = nil
  owner.tokenLock.release()
  endBorrow(owner.life, false)
  cleanup(owner)

proc accepted(owner: TcpListenerRef; stream: var TcpStream; code: int): TcpConnResult =
  result = default(TcpConnResult)
  result.code = code
  if state(owner.life) != ownerOpen:
    close(addr stream)
    result.code = ResourceClosed
  elif code == 0:
    result = takeTcpConn(stream)
    if result.code != 0: close(addr stream)

template acceptConn*(owner: TcpListenerRef; streamTimeoutMs = DefaultTimeoutMs;
                      noDelay = true; deadline: Deadline = never;
                      tok: nil CancelToken = nil): TcpConnResult =
  block:
    let held = owner
    var outcome = default(TcpConnResult)
    outcome.code = beginAccept(held, tok)
    if outcome.code == 0:
      defer: endAccept(held)
      var stream = default(TcpStream)
      let code = acceptInto(addr stream, rawListener(held), streamTimeoutMs,
                            noDelay, deadline, acceptToken(held))
      outcome = accepted(held, stream, code)
    outcome

proc startClose(owner: TcpListenerRef): int =
  result = beginClose(owner.life, true)
  if result == ResourceClosed: return 0
  if result != 0: return
  owner.tokenLock.acquire()
  if owner.accepting != nil: cancel(owner.accepting)
  owner.tokenLock.release()
  finishInterrupt(owner.life)
  cleanup(owner)

template close*(owner: TcpListenerRef; deadline: Deadline = never): int =
  ## Stop admission, cancel a pending accept, then release its descriptor only
  ## after completion. A deadline leaves safe eventual cleanup with the borrower.
  block:
    let held = owner
    var code = startClose(held)
    if code == 0: code = drainClose(ownerLife(held), deadline)
    code
