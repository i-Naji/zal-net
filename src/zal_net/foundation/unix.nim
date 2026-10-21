from zal_net/io import IoResult, ioResult
## Retained Unix stream owners. Import explicitly alongside the raw API.
## Operations are templates: their retained owner lives in the caller's frame.
## A queued task that owns a connection must take a `sink UnixConnRef` argument;
## an ordinary passive parameter is borrowed on the pinned compiler.
## Aliases share synchronized resource state.
import zal_net/[rt, errors], zal_net/rt/[sync, cancel]
import zal_net/raw/unix
import zal_net/ownership
import std/[atomics, ticketlocks]
from zal_net/raw/fdops import fdRecvInline, fdSendInline
from zal_net/buffers import dataPtr, bytesPtr, offset

export ownership

type
  UnixConnObj = object
    stream: UnixStream                ## sole stable socket owner
    life: OwnerLife                  ## synchronized admission and draining
    stop: nil CancelToken            ## one cancellation source per owner
    failureLock: TicketLock
    readFailure, writeFailure: IoFailure
    standing: int64                  ## standing deadline, 0 for none; atomic
  UnixConnRef* = ref UnixConnObj
  UnixConnResult* = object
    value*: nil UnixConnRef           ## nil on failure; caller owns on success
    code*: int                      ## zero on success, negative error otherwise

proc `=destroy`(conn: var UnixConnObj) =
  ## Every pending operation retains a reference, so destruction is quiescent.
  ## Destruction never waits or drives the runtime.
  close(addr conn.stream)
  release(conn.stop)

proc takeUnixConn*(stream: UnixStreamPtr): UnixConnResult =
  ## Transfer a quiescent raw stream with no pending borrowers. Failure preserves it.
  ## Custom-loop owners keep affinity; standard owners use shared admission.
  result = default(UnixConnResult)
  if stopping():
    result.code = ResourceClosed
    return
  if not isOpen(stream[]):
    result.code = ResourceClosed
    return
  let conn = UnixConnRef()
  initOwnerLife(conn.life)
  conn.stop = newCancelToken()
  conn.stream = takeUnix(stream)
  result.value = conn

proc takeUnixConn*(stream: var UnixStream): UnixConnResult {.inline.} =
  ## Same transfer contract, without pointer syntax in application code.
  takeUnixConn(addr stream)

proc connected(conn: UnixConnRef; code: int): UnixConnResult =
  result = default(UnixConnResult)
  result.code = code
  if code == 0:
    initOwnerLife(conn.life)
    conn.stop = newCancelToken()
    result.value = conn

proc newOwner(): UnixConnRef =
  # Same default-ref template limitation as tcpref; guarded by tconnectresult.
  UnixConnRef()

template connectUnixConn*(path: string; timeoutMs = 10_000;
                          streamTimeoutMs = DefaultTimeoutMs;
                          tok: nil CancelToken = nil; deadline: Deadline = never): UnixConnResult =
  block:
    var outcome = default(UnixConnResult)
    if stopping(): outcome.code = ResourceClosed
    else:
      let name = path
      let conn = newOwner()
      let status = connectUnixInto(addr conn.stream, name, timeoutMs, streamTimeoutMs, tok, deadline)
      outcome = connected(conn, status)
    outcome

proc state*(conn: UnixConnRef): OwnerState {.inline.} = state(conn.life)
proc cleanup(conn: UnixConnRef)
proc nativeHandle*(conn: UnixConnRef): cint =
  if beginControl(conn.life) != 0: return -1
  result = nativeHandle(conn.stream)
  endControl(conn.life)
  cleanup(conn)
proc lastReadFailure*(conn: UnixConnRef): IoFailure =
  conn.failureLock.acquire()
  result = conn.readFailure
  conn.failureLock.release()
proc lastWriteFailure*(conn: UnixConnRef): IoFailure =
  conn.failureLock.acquire()
  result = conn.writeFailure
  conn.failureLock.release()
proc recordRead*(conn: UnixConnRef; code, transferred: int) =
  conn.failureLock.acquire()
  conn.readFailure = IoFailure(code: code, transferred: transferred)
  conn.failureLock.release()
proc recordWrite*(conn: UnixConnRef; code, transferred: int) =
  conn.failureLock.acquire()
  conn.writeFailure = IoFailure(code: code, transferred: transferred)
  conn.failureLock.release()
proc idleTimeout(conn: UnixConnRef): int {.inline.} = conn.stream.timeoutMs
proc ownerStopToken(conn: UnixConnRef): nil CancelToken {.inline.} = conn.stop
proc ownerLife(conn: UnixConnRef): ptr OwnerLife {.inline.} = addr conn.life

proc deadline*(conn: UnixConnRef): Deadline =
  ## The standing deadline each read and write honours besides its own.
  let at = atomicLoad(conn.standing, moRelaxed)
  result = if at == 0: never else: Deadline(at)

proc renew*(conn: UnixConnRef; deadline: Deadline) =
  ## Replace the standing deadline; `never` clears it. A parked operation
  ## keeps the deadline it started with.
  atomicStore(conn.standing, (if deadline == never: 0'i64 else: int64(deadline)), moRelaxed)

proc bounded(conn: UnixConnRef; deadline: Deadline): Deadline {.inline.} =
  let at = atomicLoad(conn.standing, moRelaxed)
  result = if at == 0: deadline else: earlier(deadline, Deadline(at))

proc cleanup(conn: UnixConnRef) =
  if claimOwnerCleanup(conn.life):
    close(addr conn.stream)
    markClosed(conn.life)

proc endBorrow(conn: UnixConnRef; write: bool) =
  endBorrow(conn.life, write)
  cleanup(conn)

template recvInto*(conn: UnixConnRef; bytes: var openArray[byte];
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  block:
    let held = conn
    var count = beginBorrow(ownerLife(held)[], false)
    if count == 0:
      defer: endBorrow(held, false)
      fdRecvInline(nativeHandle(held), idleTimeout(held), dataPtr(bytes), bytes.len, bounded(held, deadline), count, tok, ownerStopToken(held))
      if count <= 0 and state(held) == ownerClosing: count = ResourceClosed
    count

template sendFrom*(conn: UnixConnRef; bytes: openArray[byte];
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  block:
    let held = conn
    var count = beginBorrow(ownerLife(held)[], true)
    if count == 0:
      defer: endBorrow(held, true)
      fdSendInline(nativeHandle(held), idleTimeout(held), dataPtr(bytes), bytes.len, bounded(held, deadline), count, tok, ownerStopToken(held))
      if count <= 0 and state(held) == ownerClosing: count = ResourceClosed
    count

proc startClose(conn: UnixConnRef): int =
  result = beginClose(conn.life, true)
  if result == ResourceClosed: return 0
  if result != 0: return
  cancel(conn.stop)
  interrupt(addr conn.stream)
  finishInterrupt(conn.life)
  cleanup(conn)

proc shutdownWrite*(conn: UnixConnRef): int =
  result = beginBorrow(conn.life, true)
  if result != 0: return
  shutdownWrite(addr conn.stream)
  endBorrow(conn, true)

template close*(conn: UnixConnRef; deadline: Deadline = never): int =
  ## Reject new work, interrupt borrowers, and wait for their actual completion.
  ## A deadline returns IoTimedOut while the owner remains closing; the final
  ## borrower still closes its socket. Repeated close joins the same cleanup.
  block:
    let held = conn
    var code = startClose(held)
    if code == 0:
      let life = ownerLife(held)
      code = drainClose(life, deadline)
    code


template writeAllInto*(owner: UnixConnRef; p: pointer; n: int;
                       deadline: Deadline; tok: nil CancelToken; output: var IoResult) =
  block:
    let held = owner
    let source = p
    let size = n
    let until: Deadline = bounded(held, deadline)
    let token: nil CancelToken = tok
    retain(token)
    defer: release(token)
    var sent = 0
    var code = beginBorrow(ownerLife(held)[], true)
    if code == 0:
      defer: endBorrow(held, true)
      if size < 0: code = InvalidInput
      while sent < size:
        let position = offset(bytesPtr(source), sent)
        var count = 0
        fdSendInline(nativeHandle(held), idleTimeout(held), position, size - sent, until, count, token, ownerStopToken(held))
        if count <= 0:
          code = if count < 0: count else: NoProgress
          break
        sent += count
    recordWrite(held, code, sent)
    output = ioResult(sent, code)

proc writeAll*(owner: UnixConnRef; p: pointer; n: int;
               deadline: Deadline = never; tok: nil CancelToken = nil): IoResult {.passive.} =
  result = default(IoResult)
  writeAllInto(owner, p, n, deadline, tok, result)

template writeAll*(owner: UnixConnRef; buffer: openArray[byte];
                   deadline: Deadline = never; cancel: nil CancelToken = nil): IoResult =
  block:
    let held = owner
    let bytes: openArray[byte] = buffer
    writeAll(held, dataPtr(bytes), bytes.len, deadline, cancel)
