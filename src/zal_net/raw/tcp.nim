## TCP: streams and listeners.
##
## Three levels:
## - primitives, pointer and length (`recvInto`, `sendFrom`, the vectored
##   forms), each one system call attempt, parking only when the kernel
##   would block; this is what protocol code and relays use;
## - helpers (`readExactly`, `writeAll`, `write` of a string);
## - sugar over `openArray` (`recv`, `send`, and the helpers' openArray
##   forms): templates, so they cost nothing over the primitives.
##
## Every wait ends at the earlier of the stream's idle limit (`timeoutMs`,
## per operation; 0 none) and the operation's `deadline`. Results: >0
## bytes, 0 EOF (reads), <0 an error or IoTimedOut. A stream is owned by
## the task using it; its descriptor is `nativeHandle` for anything this
## module does not cover (see net/options and net/advanced).
##
## ```nim
## proc echo(s: TcpStreamPtr): int {.passive.} =
##   var buf = default(array[8192, byte])
##   while true:
##     let n = recv(s, buf)
##     if n <= 0 or not writeAll(s, buf.toOpenArray(0, n - 1)): break
##   result = 0
##
## initRuntime()
## let l = listenTcp(8080)
## serve(l, echo)
## drainRuntime()
## ```

import zal_net/private/socketowner
import zal_net/net/dns
import zal_net/errors
import std/atomics
import std/oserrors
import zal_net/rt
import zal_net/raw/io
import zal_net/rt/sync
import zal_net/rt/cancel
import zal_net/private/core/iocancel
import zal_net/private/sharedmem
import zal_net/private/sys/posix
import zal_net/private/core/waitq
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/net/address
import zal_net/raw/fdops
import zal_net/private/sys/sock

export Shutdown, DefaultTimeoutMs

const
  AttemptDelayMs* = 250          ## Happy Eyeballs: the next address after this long

type
  TcpStream* = object
    socket: SocketOwner          ## sole owner; address-stable while borrowed
    timeoutMs*: int              ## idle limit per operation (0: none)

  TcpListener* = object
    socket: SocketOwner          ## zero initialized or closed: no descriptor
    local*: SocketAddress        ## the bound address (the port, with port 0)
    error*: string

  TcpStreamPtr* = ptr TcpStream
  TcpListenerPtr* = ptr TcpListener

  TcpHandler* = proc (s: TcpStreamPtr): int {.nimcall, passive.}
    ## Runs once per accepted connection, in its own chain; `serve` closes
    ## the stream when it returns (unless the handler did).


proc fd(s: TcpStream): cint {.inline.} = handle(s.socket)
proc fd(s: TcpStreamPtr): cint {.inline.} = handle(s.socket)
proc fd(l: TcpListener): cint {.inline.} = handle(l.socket)

proc takeTcp*(s: TcpStreamPtr): TcpStream =
  ## Transfer a quiescent stream. No operation may still borrow its old owner.
  result = s[]
  s.socket = default(SocketOwner)

proc takeTcpListener*(l: TcpListenerPtr): TcpListener =
  ## Transfer only when no accept or serving-loop close still borrows this owner.
  result = l[]
  l.socket = default(SocketOwner)

proc adoptTcp*(s: TcpStreamPtr; descriptor: var cint; timeoutMs = DefaultTimeoutMs): bool =
  ## Adopt a nonblocking connected socket. On success descriptor becomes -1;
  ## on failure both owners are unchanged. The stream must already be closed.
  if fd(s[]) >= 0 or descriptor < 0: return false
  s.socket = ownedSocket(descriptor)
  s.timeoutMs = timeoutMs
  descriptor = -1
  result = true

proc takeNativeHandle*(s: TcpStreamPtr): cint =
  ## Detach a quiescent socket without closing it. Caller assumes ownership.
  takeHandle(s.socket)

proc isOpen*(s: TcpStream): bool {.inline.} = s.fd >= 0
proc nativeHandle*(s: TcpStream): cint {.inline.} = s.fd
proc nativeHandle*(s: TcpStreamPtr): cint {.inline.} = s.fd
proc ok*(l: TcpListener): bool {.inline.} = l.fd >= 0
proc nativeHandle*(l: TcpListener): cint {.inline.} = l.fd
proc port*(l: TcpListener): uint16 {.inline.} = port(l.local)

# -------------------------------------------------------------- primitives

proc recvInto*(s: TcpStreamPtr; p: pointer; n: int; deadline = never; tok: nil CancelToken = nil): int {.passive.} =
  ## Up to `n` bytes into p: how many, 0 at EOF, <0 on an error or timeout.
  result = fdRecv(s.fd, s.timeoutMs, p, n, deadline, tok)

proc sendFrom*(s: TcpStreamPtr; p: pointer; n: int; deadline = never; tok: nil CancelToken = nil): int {.passive.} =
  ## Some of the `n` bytes at p (at least one): how many, <0 on an error or
  ## timeout.
  result = fdSend(s.fd, s.timeoutMs, p, n, deadline, tok)

proc recvVectored*(s: TcpStreamPtr; iov: ptr IoVec; count: int; deadline = never; tok: nil CancelToken = nil): int {.passive.} =
  ## One readv into `count` buffers: bytes read, 0 at EOF, <0 as `recvInto`.
  result = fdRecvv(s.fd, s.timeoutMs, iov, count, deadline, tok)

proc sendVectored*(s: TcpStreamPtr; iov: ptr IoVec; count: int; deadline = never; tok: nil CancelToken = nil): int {.passive.} =
  ## One writev of `count` buffers (possibly partial): bytes written, <0 on
  ## an error or timeout.
  result = fdSendv(s.fd, s.timeoutMs, iov, count, deadline, tok)

proc shutdown*(s: TcpStreamPtr; how = shutWrite) =
  ## shutWrite is the half-close a proxy forwards (the peer reads EOF,
  ## reading goes on); shutBoth also wakes a task parked on the stream.
  fdShutdown(s.fd, ord(how))
proc shutdownWrite*(s: TcpStreamPtr) = fdShutdown(s.fd, 1)
proc interrupt*(s: TcpStreamPtr) =
  ## Wake whatever is parked on the stream and fail what follows (both
  ## directions shut down); the descriptor stays open until `close`.
  fdShutdown(s.fd, 2)

proc close*(s: TcpStreamPtr) =
  if s.fd >= 0:
    closeFd(takeHandle(s.socket))

proc abort*(s: TcpStreamPtr) =
  ## Close with a reset (RST) instead of a FIN.
  if s.fd >= 0:
    lingerRst(takeHandle(s.socket))

proc localAddress*(s: TcpStream): SocketAddress = fdLocal(s.fd)
proc remoteAddress*(s: TcpStream): SocketAddress = fdRemote(s.fd)

proc setNoDelay*(s: TcpStream; on = true) =
  if s.fd >= 0: setIntOpt(s.fd, IPPROTO_TCP, TCP_NODELAY, cint(ord(on)))

# ------------------------------------------------------------------ helpers

proc readExactly*(s: TcpStreamPtr; p: pointer; n: int; deadline = never; tok: nil CancelToken = nil): bool {.passive.} =
  ## Exactly `n` bytes (never more: what follows stays in the socket).
  result = fdReadExactly(s.fd, s.timeoutMs, p, n, deadline, tok)

proc writeAll*(s: TcpStreamPtr; p: pointer; n: int; deadline = never; tok: nil CancelToken = nil): bool {.passive.} =
  result = fdWriteAll(s.fd, s.timeoutMs, p, n, deadline, tok)

proc write*(s: TcpStreamPtr; data: string; deadline = never; tok: nil CancelToken = nil): bool {.passive.} =
  var bytes = data
  result = bytes.len == 0 or fdWriteAll(s.fd, s.timeoutMs, cast[pointer](bytes.toCString), bytes.len, deadline, tok)

template recvInto*(s: TcpStreamPtr; buf: var openArray[byte]; deadline: Deadline = never; tok: nil CancelToken = nil): int =
  recvInto(s, dataPtr(buf), buf.len, deadline, tok)

template sendFrom*(s: TcpStreamPtr; buf: openArray[byte]; deadline: Deadline = never; tok: nil CancelToken = nil): int =
  sendFrom(s, dataPtr(buf), buf.len, deadline, tok)

template recv*(s: TcpStreamPtr; buf: var openArray[byte]; deadline: Deadline = never; tok: nil CancelToken = nil): int =
  recvInto(s, buf, deadline, tok)

template send*(s: TcpStreamPtr; buf: openArray[byte]; deadline: Deadline = never; tok: nil CancelToken = nil): int =
  sendFrom(s, buf, deadline, tok)

template readExactly*(s: TcpStreamPtr; buf: var openArray[byte]; deadline: Deadline = never; tok: nil CancelToken = nil): bool =
  readExactly(s, dataPtr(buf), buf.len, deadline, tok)

template writeAll*(s: TcpStreamPtr; buf: openArray[byte]; deadline: Deadline = never; tok: nil CancelToken = nil): bool =
  writeAll(s, dataPtr(buf), buf.len, deadline, tok)

# ----------------------------------------------------------------- connect

proc connectInto*(stream: TcpStreamPtr; a: SocketAddress; timeoutMs = 10_000;
                  noDelay = true; streamTimeoutMs = DefaultTimeoutMs;
                  tok: nil CancelToken = nil; deadline = never): int {.passive.} =
  ## Open a closed, address-stable owner. Zero success, negative failure.
  ## Failure preserves the owner's fields; a live owner returns ResourceBusy.
  if isOpen(stream[]): return ResourceBusy
  retain(tok)
  defer: release(tok)
  if cancelled(tok): return ECancelled
  if stopping(): return ResourceClosed
  if not isValid(a) or a.raw.len > cuint(sizeof(SockaddrStorage)): return InvalidInput
  let endAt = earlier(deadline, afterMs(timeoutMs))
  if monoNow() >= endAt: return IoTimedOut
  var pending = false
  var error = 0
  let fd = startConnect(unsafeAddr a.raw, noDelay, pending, error)
  if fd < 0: return error
  if pending:
    parkConnectOutcome(fd, endAt, tok, error)
    if error != 0:
      closeFd(fd)
      return error
  if cancelled(tok) or stopping():
    closeFd(fd)
    return (if cancelled(tok): ECancelled else: ResourceClosed)
  stream.socket = ownedSocket(fd)
  stream.timeoutMs = streamTimeoutMs
  result = 0

template connect*(a: SocketAddress; timeoutMs = 10_000; noDelay = true;
                  streamTimeoutMs = DefaultTimeoutMs; tok: nil CancelToken = nil;
                  deadline: Deadline = never): TcpStream =
  ## Value convenience; use connectInto when the exact failure is needed.
  block:
    var owner = default(TcpStream)
    discard connectInto(addr owner, a, timeoutMs, noDelay, streamTimeoutMs, tok, deadline)
    owner

type
  Race = object
    ## Shared by a Happy Eyeballs connect and its attempts.
    refs: int                    # atomic
    winner: int                  # atomic: the connected descriptor, -1
    failed: int                  # atomic: attempts that failed
    error: int                   # atomic: first failed attempt's negative code
    total: int
    done: Event
    kick: Notify                 # an attempt failed: later ones may start early
    tok: CancelToken             # cancels the attempts still connecting

proc releaseRace(r: ptr Race) =
  if atomicFetchSub(r.refs, 1, moAcquireRelease) == 1:
    release(r.tok)
    freeShared(r)

proc recordFailure(r: ptr Race; code: int) =
  var expected = 0
  if code < 0: discard atomicCompareExchange(r.error, expected, code, moRelease, moRelaxed)

proc attempt(r: ptr Race; sa: SocketAddress; index: int; start: Deadline; deadline: Deadline;
             noDelay: bool) {.passive.} =
  ## One address: wait for its turn (or an earlier failure), connect, and
  ## claim the win or record the failure.
  let myTurn = Deadline(int64(start) + int64(index) * int64(AttemptDelayMs) * 1_000_000)
  while atomicLoad(r.winner, moAcquire) < 0 and atomicLoad(r.failed, moAcquire) < index and
        monoNow() < myTurn and monoNow() < deadline and not cancelled(r.tok):
    discard wait(addr r.kick, earlier(myTurn, deadline), r.tok)
  var won = false
  var code = ResourceClosed
  if cancelled(r.tok): code = ECancelled
  elif monoNow() >= deadline: code = IoTimedOut
  elif atomicLoad(r.winner, moAcquire) < 0:
    var pending = false
    let fd = startConnect(unsafeAddr sa.raw, noDelay, pending, code)
    if fd >= 0:
      adoptFd(r.tok, fd)
      if pending: parkConnectOutcome(fd, deadline, r.tok, code)
      releaseFd(r.tok, fd)
      if code == 0 and not cancelled(r.tok):
        var expected = -1
        if atomicCompareExchange(r.winner, expected, int(fd)):
          won = true
          setEvent(addr r.done)
      if not won: closeFd(fd)
  if not won:
    recordFailure(r, code)
    if atomicFetchAdd(r.failed, 1, moAcquireRelease) + 1 == r.total: setEvent(addr r.done)
    notifyAll(addr r.kick)
  releaseRace(r)

proc interleave(addrs: seq[SocketAddress]): seq[SocketAddress] =
  ## RFC 8305: alternate families, starting with the resolver's first.
  result = @[]
  var a: seq[SocketAddress] = @[]
  var b: seq[SocketAddress] = @[]
  if addrs.len == 0: return
  let first = family(addrs[0])
  for x in addrs:
    if family(x) == first: a.add x else: b.add x
  var i = 0
  while i < a.len or i < b.len:
    if i < a.len: result.add a[i]
    if i < b.len: result.add b[i]
    i = i + 1

proc connectInto*(stream: TcpStreamPtr; host: string; port: uint16;
                  timeoutMs = 10_000; noDelay = true;
                  streamTimeoutMs = DefaultTimeoutMs; tok: nil CancelToken = nil;
                  deadline = never): int {.passive.} =
  ## Resolve `host` (off the loop; numbers at once) and connect with Happy
  ## Eyeballs (RFC 8305): addresses alternate between families, a new
  ## attempt starts every 250 ms (or as soon as one fails), the first to
  ## connect wins and the rest are cancelled. Zero on success; when all fail,
  ## return the first failed attempt's code. The owner is unchanged on failure.
  if isOpen(stream[]): return ResourceBusy
  retain(tok)
  defer: release(tok)
  let endAt = earlier(deadline, afterMs(timeoutMs))
  if cancelled(tok): return ECancelled
  if stopping(): return ResourceClosed
  var resolved = default(array[MaxAddrs, SockAddrBuf])
  let count = resolveAsync(host, port, SOCK_STREAM, 0.cint, resolveBuffer(resolved), endAt, tok)
  if count < 0: return count
  if cancelled(tok): return ECancelled
  if monoNow() >= endAt: return IoTimedOut
  var addresses: seq[SocketAddress] = @[]
  for index in 0..<count: addresses.add SocketAddress(raw: resolved[index])
  let addrs = interleave(addresses)
  if addrs.len == 0: return DnsNoAddresses
  if addrs.len == 1:
    result = connectInto(stream, addrs[0], timeoutMs, noDelay, streamTimeoutMs, tok, endAt)
    return
  let r = cast[ptr Race](requireShared(sizeof(Race)))
  r.refs = 1 + addrs.len
  r.winner = -1
  r.total = addrs.len
  r.tok = newCancelToken(tok)
  let start = monoNow()
  var i = 0
  while i < addrs.len:
    if not trySpawnTask(attempt(r, addrs[i], i, start, endAt, noDelay)):
      recordFailure(r, ResourceClosed)
      if atomicFetchAdd(r.failed, 1, moAcquireRelease) + 1 == r.total:
        setEvent(addr r.done)
      releaseRace(r)
    i = i + 1
  let outcome = wait(addr r.done, endAt, tok)
  var fd = atomicLoad(r.winner, moAcquire)
  if fd < 0:
    # Nobody yet: claim the slot so a late success closes its own socket.
    var expected = -1
    if not atomicCompareExchange(r.winner, expected, high(int)): fd = expected
  result = atomicLoad(r.error, moAcquire)
  if cancelled(tok) or outcome == wrCancelled: result = ECancelled
  elif outcome == wrTimedOut: result = IoTimedOut
  elif stopping(): result = ResourceClosed
  elif result == 0: result = ResourceClosed
  cancel(r.tok)                   # the attempts still connecting give up now
  if fd >= 0 and fd != high(int):
    if outcome == wrReady and not cancelled(tok) and not stopping():
      stream.socket = ownedSocket(cint(fd))
      stream.timeoutMs = streamTimeoutMs
      result = 0
    else:
      closeFd(cint(fd))
  releaseRace(r)

template connect*(host: string; port: uint16; timeoutMs = 10_000; noDelay = true;
                  streamTimeoutMs = DefaultTimeoutMs; tok: nil CancelToken = nil;
                  deadline: Deadline = never): TcpStream =
  block:
    let name = host
    var owner = default(TcpStream)
    discard connectInto(addr owner, name, port, timeoutMs, noDelay, streamTimeoutMs, tok, deadline)
    owner

# ------------------------------------------------------------ listen/accept

proc listenInto*(owner: TcpListenerPtr; port: uint16; host = "";
                 backlog = 1024; noDelay = true; reusePort = false): int =
  ## Install one listener in a closed, address-stable owner. Failure preserves
  ## every owner field and returns the native or library error.
  if owner[].ok: return ResourceBusy
  if stopping(): return ResourceClosed
  let opened = tryListenTcp(port, backlog, host, noDelay, reusePort)
  if not opened.ok: return opened.code
  var local = default(SocketAddress)
  local.raw.len = cuint(sizeof(SockaddrStorage))
  if sockGetsockname(opened.fd, addr local.raw.ss, addr local.raw.len) != 0:
    let code = -int(osLastError())
    discard unregisterIdleListener(opened.fd)
    closeFd(opened.fd)
    return code
  owner.socket = ownedSocket(opened.fd)
  owner.local = local
  owner.error = ""
  result = 0


proc listen*(a: SocketAddress; backlog = 1024; noDelay = true; reusePort = false): TcpListener =
  ## Listen on `a`; an unspecified address binds every address. Port zero asks
  ## the kernel for a port. The returned raw owner must be kept stable.
  result = default(TcpListener)
  let address = unmapped(ip(a))
  let host = if isUnspecified(address): "" else: $address
  let code = listenInto(addr result, port(a), host, backlog, noDelay, reusePort)
  if code != 0: result.error = errors.describe(code)

proc listenTcp*(port: uint16; host = ""; backlog = 1024; noDelay = true; reusePort = false): TcpListener =
  ## Listen on `host` (all addresses when empty). For exact failure results use
  ## listenInto; this convenience constructor records a diagnostic string.
  result = default(TcpListener)
  let code = listenInto(addr result, port, host, backlog, noDelay, reusePort)
  if code != 0: result.error = errors.describe(code)


proc acceptInto*(stream: TcpStreamPtr; listener: TcpListenerPtr;
                 streamTimeoutMs = DefaultTimeoutMs; noDelay = true;
                 deadline: Deadline = never; tok: nil CancelToken = nil): int {.passive.} =
  ## One pending accept per listener per loop. Both owners remain stable until
  ## completion. Cancellation only ends this wait: the listener stays usable.
  ## Success transfers the accepted socket; failure preserves the output owner.
  if isOpen(stream[]): return ResourceBusy
  if not listener[].ok: return ResourceClosed
  retain(tok)
  defer: release(tok)
  while true:
    if cancelled(tok): return ECancelled
    if stopping(): return ResourceClosed
    if monoNow() >= deadline: return IoTimedOut
    let fd = acceptNow(listener[].fd)
    if fd >= 0:
      if cancelled(tok) or stopping():
        closeFd(cint(fd))
        return (if cancelled(tok): ECancelled else: ResourceClosed)
      tuneAccepted(cint(fd), noDelay)
      stream.socket = ownedSocket(cint(fd))
      stream.timeoutMs = streamTimeoutMs
      return 0
    if fd == AcceptClosed: return ResourceClosed
    if fd == AcceptBusy:
      parkUntil(earlier(deadline, afterMs(CancelPollMs)))
    elif fd == AcceptAgain:
      var ready = 0
      parkAcceptCancellable(listener[].fd, deadline, tok, ready)
      if ready <= 0: return (if ready < 0: ready else: ResourceClosed)
    else:
      return fd

template accept*(l: TcpListener; streamTimeoutMs = DefaultTimeoutMs; noDelay = true;
                  deadline: Deadline = never; tok: nil CancelToken = nil): TcpStream =
  block:
    var listener = l                 # borrowed descriptor, not a second owner
    var stream = default(TcpStream)
    discard acceptInto(addr stream, addr listener, streamTimeoutMs, noDelay, deadline, tok)
    stream

proc runHandler(fd: cint; h: TcpHandler; timeoutMs: int) {.passive.} =
  var s = TcpStream(socket: ownedSocket(fd), timeoutMs: timeoutMs)
  discard h(addr s)
  close(addr s)

proc acceptLoop(fd: cint; h: TcpHandler; timeoutMs: int; noDelay: bool) {.passive.} =
  while true:
    let c = waitAccept(fd)
    if c < 0: break
    tuneAccepted(cint(c), noDelay)
    if not tryStartConn(runHandler(cint(c), h, timeoutMs)):
      closeFd(cint(c))
      break

proc serve*(l: TcpListener; h: TcpHandler; streamTimeoutMs = DefaultTimeoutMs; noDelay = true) =
  ## Accept on every loop and run `h` for each connection. Before `drainRuntime`
  ## or from any thread later; `close(l)` ends it.
  if l.fd >= 0: spawnTask acceptLoop(l.fd, h, streamTimeoutMs, noDelay)

proc close*(l: var TcpListener): bool {.passive.} =
  ## Stop the accept loops and close; the port is free when this returns
  ## true.
  if l.fd < 0: return true
  result = closeListener(l.fd) == wrReady
  if result: discard takeHandle(l.socket)

proc closeNow*(l: var TcpListener) =
  ## Close a quiescent listener with no accept loops or pending accepts.
  ## A listener already closing keeps its descriptor until acknowledgements
  ## complete through `close`; this call does not bypass that protocol.
  if l.fd >= 0 and unregisterIdleListener(l.fd):
    closeFd(takeHandle(l.socket))
