## Retained listener owner. One pending accept is admitted.
## A queued task retaining this owner must use a `sink UnixListenerRef` parameter.
## Accepted connections belong to the caller; closing the listener does not
## close connections already returned. Import explicitly with unixref.
import zal_net/[rt, errors], zal_net/rt/[sync, cancel], zal_net/raw/io
import zal_net/raw/unix, zal_net/foundation/unix, zal_net/ownership
import zal_net/ownership
import std/ticketlocks

export ownership

type
  UnixListenerObj = object
    listener: UnixListener             ## sole, stable raw owner
    life: OwnerLife
    tokenLock: TicketLock
    accepting: nil CancelToken       ## owned child, retained until accept ends
  UnixListenerRef* = ref UnixListenerObj
  UnixListenerResult* = object
    value*: nil UnixListenerRef        ## caller owns on success
    code*: int                       ## zero success; negative error otherwise

proc `=destroy`(owner: var UnixListenerObj) =
  ## Pending operations retain this object. Destruction never blocks.
  closeNow(owner.listener)
  release(owner.accepting)

proc takeUnixListenerRef*(listener: UnixListenerPtr): UnixListenerResult =
  ## Transfer a quiescent listener. No raw accept or serve may still borrow it.
  ## Failure preserves the raw owner.
  result = default(UnixListenerResult)
  if stopping(): return UnixListenerResult(code: ResourceClosed)
  if not listener[].ok: return UnixListenerResult(code: ResourceClosed)
  if listenerClosing(nativeHandle(listener[])):
    return UnixListenerResult(code: ResourceBusy)
  let owner = UnixListenerRef()
  initOwnerLife(owner.life)
  owner.listener = takeUnixListener(listener)
  result.value = owner

proc takeUnixListenerRef*(listener: var UnixListener): UnixListenerResult {.inline.} =
  takeUnixListenerRef(addr listener)

proc listenUnixRef*(path: string; backlog = 1024): UnixListenerResult =
  ## Failed construction owns no descriptor or path; existing owners stay usable.
  result = default(UnixListenerResult)
  if stopping(): return UnixListenerResult(code: ResourceClosed)
  let owner = UnixListenerRef()
  result.code = listenUnixInto(addr owner.listener, path, backlog)
  if result.code == 0:
    initOwnerLife(owner.life)
    result.value = owner

proc state*(owner: UnixListenerRef): OwnerState {.inline.} = state(owner.life)
proc cleanup(owner: UnixListenerRef)
proc finishControl(owner: UnixListenerRef) =
  endControl(owner.life)
  signalIdle(owner.life)
  cleanup(owner)

proc nativeHandle*(owner: UnixListenerRef): cint =
  if beginControl(owner.life) != 0: return -1
  result = nativeHandle(owner.listener)
  finishControl(owner)
proc path*(owner: UnixListenerRef): string =
  if beginControl(owner.life) != 0: return ""
  result = owner.listener.path
  finishControl(owner)

proc beginAccept(owner: UnixListenerRef; tok: nil CancelToken): int =
  owner.tokenLock.acquire()
  result = beginBorrow(owner.life, false)
  if result == 0:
    # One child per accept operation, never per established I/O iteration.
    # It combines caller cancellation and listener close without shutting down
    # or recycling a descriptor while a poll may still reference it.
    owner.accepting = newCancelToken(tok)

  owner.tokenLock.release()

proc rawListener(owner: UnixListenerRef): UnixListenerPtr {.inline.} = addr owner.listener
proc acceptToken(owner: UnixListenerRef): nil CancelToken {.inline.} = owner.accepting
proc ownerLife(owner: UnixListenerRef): ptr OwnerLife {.inline.} = addr owner.life

proc cleanup(owner: UnixListenerRef) =
  if claimOwnerCleanup(owner.life):
    closeNow(owner.listener)
    markClosed(owner.life)

proc endAccept(owner: UnixListenerRef) =
  owner.tokenLock.acquire()
  release(owner.accepting)
  owner.accepting = nil
  owner.tokenLock.release()
  endBorrow(owner.life, false)
  signalIdle(owner.life)
  cleanup(owner)

proc accepted(owner: UnixListenerRef; stream: var UnixStream; code: int): UnixConnResult =
  result = default(UnixConnResult)
  result.code = code
  if state(owner.life) != ownerOpen:
    close(addr stream)
    result.code = ResourceClosed
  elif code == 0:
    result = takeUnixConn(stream)
    if result.code != 0: close(addr stream)

template acceptConn*(owner: UnixListenerRef; streamTimeoutMs = DefaultTimeoutMs;
                      deadline: Deadline = never;
                      tok: nil CancelToken = nil): UnixConnResult =
  block:
    let held = owner
    var outcome = default(UnixConnResult)
    outcome.code = beginAccept(held, tok)
    if outcome.code == 0:
      defer: endAccept(held)
      var stream = default(UnixStream)
      let code = acceptUnixInto(addr stream, rawListener(held), streamTimeoutMs,
                                deadline, acceptToken(held))
      outcome = accepted(held, stream, code)
    outcome

proc startClose(owner: UnixListenerRef): int =
  result = beginClose(owner.life, true)
  if result == ResourceClosed: return 0
  if result != 0: return
  owner.tokenLock.acquire()
  if owner.accepting != nil: cancel(owner.accepting)
  owner.tokenLock.release()
  finishInterrupt(owner.life)
  cleanup(owner)

template close*(owner: UnixListenerRef; deadline: Deadline = never): int =
  ## Stop admission, cancel a pending accept, then release its descriptor only
  ## after completion. A deadline leaves safe eventual cleanup with the borrower.
  block:
    let held = owner
    var code = startClose(held)
    if code == 0: code = drainClose(ownerLife(held), deadline)
    code
