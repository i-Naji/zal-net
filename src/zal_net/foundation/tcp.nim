from zal_net/io import IoResult, ioResult
## Retained TCP owners. Import explicitly alongside the raw API.
## Operations are templates: their retained owner lives in the caller's frame.
## A queued task that owns a connection must take a `sink TcpConnRef` argument;
## an ordinary passive parameter is borrowed on the pinned compiler.
## Aliases share synchronized resource state.
import zal_net/[rt, errors, buffers], zal_net/rt/[sync, cancel]
import zal_net/raw/tcp
from zal_net/raw/fdops import fdRecvInline, fdSendInline
import zal_net/net/stream as copying
import zal_net/net/address
import zal_net/ownership
import std/ticketlocks

export ownership

type
  TcpConnObj = object
    stream: TcpStream                ## sole stable socket owner
    life: OwnerLife                  ## synchronized admission and draining
    stop: nil CancelToken            ## one cancellation source per owner
    failureLock: TicketLock
    readFailure, writeFailure: IoFailure
  TcpConnRef* = ref TcpConnObj
  TcpConnResult* = object
    value*: nil TcpConnRef           ## nil on failure; caller owns on success
    code*: int                      ## zero on success, negative error otherwise

proc `=destroy`(conn: var TcpConnObj) =
  ## Every pending operation retains a reference, so destruction is quiescent.
  ## Destruction never waits or drives the runtime.
  close(addr conn.stream)
  release(conn.stop)

proc takeTcpConn*(stream: TcpStreamPtr): TcpConnResult =
  ## Transfer a quiescent raw stream with no pending borrowers. Failure preserves it.
  ## Custom-loop owners retain their creating loop; standard owners use shared admission.
  result = default(TcpConnResult)
  if stopping():
    result.code = ResourceClosed
    return
  if not isOpen(stream[]):
    result.code = ResourceClosed
    return
  let conn = TcpConnRef()
  initOwnerLife(conn.life)
  conn.stop = newCancelToken()
  conn.stream = takeTcp(stream)
  result.value = conn

proc takeTcpConn*(stream: var TcpStream): TcpConnResult {.inline.} =
  ## Same transfer contract, without pointer syntax in application code.
  takeTcpConn(addr stream)

proc connected(conn: TcpConnRef; code: int): TcpConnResult =
  result = default(TcpConnResult)
  result.code = code
  if code == 0:
    initOwnerLife(conn.life)
    conn.stop = newCancelToken()
    result.value = conn

proc newOwner(): TcpConnRef =
  # The pin rejects recursively defaulted ref construction inside these
  # forwarding templates. Keep allocation typed; tconnectresult guards it.
  TcpConnRef()

template connectTcpConn*(a: SocketAddress; timeoutMs = 10_000; noDelay = true;
                         streamTimeoutMs = DefaultTimeoutMs;
                         tok: nil CancelToken = nil; deadline: Deadline = never): TcpConnResult =
  block:
    var outcome = default(TcpConnResult)
    if stopping(): outcome.code = ResourceClosed
    else:
      let conn = newOwner()
      let status = connectInto(addr conn.stream, a, timeoutMs, noDelay, streamTimeoutMs, tok, deadline)
      outcome = connected(conn, status)
    outcome

template connectTcpConn*(host: string; port: uint16; timeoutMs = 10_000;
                         noDelay = true; streamTimeoutMs = DefaultTimeoutMs;
                         tok: nil CancelToken = nil; deadline: Deadline = never): TcpConnResult =
  block:
    var outcome = default(TcpConnResult)
    if stopping(): outcome.code = ResourceClosed
    else:
      let name = host
      let conn = newOwner()
      let status = connectInto(addr conn.stream, name, port, timeoutMs, noDelay, streamTimeoutMs, tok, deadline)
      outcome = connected(conn, status)
    outcome

proc state*(conn: TcpConnRef): OwnerState {.inline.} = state(conn.life)
proc cleanup(conn: TcpConnRef)
proc nativeHandle*(conn: TcpConnRef): cint =
  if beginControl(conn.life) != 0: return -1
  result = nativeHandle(conn.stream)
  endControl(conn.life)
  cleanup(conn)

proc lastReadFailure*(conn: TcpConnRef): IoFailure =
  conn.failureLock.acquire()
  result = conn.readFailure
  conn.failureLock.release()
proc lastWriteFailure*(conn: TcpConnRef): IoFailure =
  conn.failureLock.acquire()
  result = conn.writeFailure
  conn.failureLock.release()

proc recordRead*(conn: TcpConnRef; code: int; transferred = 0) =
  conn.failureLock.acquire()
  conn.readFailure = IoFailure(code: code, transferred: transferred)
  conn.failureLock.release()

proc recordWrite*(conn: TcpConnRef; code: int; transferred = 0) =
  conn.failureLock.acquire()
  conn.writeFailure = IoFailure(code: code, transferred: transferred)
  conn.failureLock.release()

proc ownerLife(conn: TcpConnRef): ptr OwnerLife {.inline.} = addr conn.life
proc streamPointer(conn: TcpConnRef): TcpStreamPtr {.inline.} = addr conn.stream
proc idleTimeout(conn: TcpConnRef): int {.inline.} = conn.stream.timeoutMs
proc ownerStopToken(conn: TcpConnRef): nil CancelToken {.inline.} = conn.stop

proc quiescent*(conn: TcpConnRef): bool {.inline.} =
  isIdle(conn.life)

proc cleanup(conn: TcpConnRef) =
  if claimOwnerCleanup(conn.life):
    close(addr conn.stream)
    markClosed(conn.life)

proc endBorrow(conn: TcpConnRef; write: bool) =
  endBorrow(conn.life, write)
  signalIdle(conn.life)
  cleanup(conn)

proc shutdownWrite*(conn: TcpConnRef): int =
  result = beginBorrow(conn.life, true)
  if result != 0: return
  shutdownWrite(addr conn.stream)
  endBorrow(conn, true)

proc interrupt*(conn: TcpConnRef): int =
  result = beginControl(conn.life)
  if result != 0: return
  interrupt(addr conn.stream)
  endControl(conn.life)
  cleanup(conn)

template recvInto*(conn: TcpConnRef; p: pointer; n: int;
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  block:
    let held = conn
    var count = beginBorrow(ownerLife(held)[], false)
    if count == 0:
      defer: endBorrow(held, false)
      let buffer = p
      fdRecvInline(nativeHandle(held), idleTimeout(held), buffer, n, deadline, count, tok, ownerStopToken(held))
      if count <= 0 and state(held) == ownerClosing: count = ResourceClosed
    count

template sendFrom*(conn: TcpConnRef; p: pointer; n: int;
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  block:
    let held = conn
    var count = beginBorrow(ownerLife(held)[], true)
    if count == 0:
      defer: endBorrow(held, true)
      let buffer = p
      fdSendInline(nativeHandle(held), idleTimeout(held), buffer, n, deadline, count, tok, ownerStopToken(held))
      if count <= 0 and state(held) == ownerClosing: count = ResourceClosed
    count

template recvInto*(conn: TcpConnRef; bytes: var openArray[byte];
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  recvInto(conn, dataPtr(bytes), bytes.len, deadline, tok)

template sendFrom*(conn: TcpConnRef; bytes: openArray[byte];
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  sendFrom(conn, dataPtr(bytes), bytes.len, deadline, tok)

proc startClose(conn: TcpConnRef; requireIdle = false): int =
  result = beginClose(conn.life, true, requireIdle)
  if result == ResourceClosed: return 0 # Repeated close joins the first owner.
  if result != 0: return
  cancel(conn.stop)
  interrupt(addr conn.stream)
  finishInterrupt(conn.life)
  cleanup(conn)

proc closeNow*(conn: TcpConnRef): int =
  ## Quiescent nonblocking disposal for stream adapters. Failure preserves the
  ## owner; asynchronous close remains necessary while operations borrow it.
  result = startClose(conn, true)

proc takeRawTcp*(conn: TcpConnRef; output: var TcpStream): int =
  ## Transfer a quiescent friendly owner to a stable raw owner. All aliases
  ## observe the old owner closed. Failure preserves both owners.
  if output.isOpen: return ResourceBusy
  result = beginTransfer(conn.life)
  if result != 0: return
  output = takeTcp(addr conn.stream)
  markClosed(conn.life)
  result = 0


template close*(conn: TcpConnRef; deadline: Deadline = never): int =
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

template copy*(source, destination: TcpConnRef; idleMs = 0; splice = true;
               tok: nil CancelToken = nil): copying.CopyStats =
  ## Borrow each direction for the entire copy. The enclosing caller retains
  ## both stable owners; raw built-in copying retains its flat I/O path.
  block:
    let reading = source
    let writing = destination
    var copied = default(copying.CopyStats)
    if reading == writing:
      copied.error = InvalidInput
    else:
      copied.error = beginBorrow(ownerLife(reading)[], false)
      if copied.error == 0:
        defer: endBorrow(reading, false)
        copied.error = beginBorrow(ownerLife(writing)[], true)
        if copied.error == 0:
          defer: endBorrow(writing, true)
          copied = copying.copy(streamPointer(reading), streamPointer(writing), idleMs, splice, tok, ownerStopToken(reading), ownerStopToken(writing))
          if state(reading.life) == ownerClosing or state(writing.life) == ownerClosing:
            copied.error = ResourceClosed
    copied


template writeAllInto*(owner: TcpConnRef; p: pointer; n: int;
                       deadline: Deadline; tok: nil CancelToken; output: var IoResult) =
  block:
    let held = owner
    let source = p
    let size = n
    let until: Deadline = deadline
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

proc writeAll*(owner: TcpConnRef; p: pointer; n: int;
               deadline: Deadline = never; tok: nil CancelToken = nil): IoResult {.passive.} =
  result = default(IoResult)
  writeAllInto(owner, p, n, deadline, tok, result)

template writeAll*(owner: TcpConnRef; buffer: openArray[byte];
                   deadline: Deadline = never; cancel: nil CancelToken = nil): IoResult =
  block:
    let held = owner
    let bytes: openArray[byte] = buffer
    writeAll(held, dataPtr(bytes), bytes.len, deadline, cancel)
