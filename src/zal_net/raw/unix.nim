## Unix-domain sockets: streams (the same operations as `TcpStream`),
## listeners, and datagrams. Paths are at most 103 bytes; a listener
## replaces a stale socket file and removes its file on close. On Linux,
## a path "@name" is in the abstract namespace (no file at all).

import zal_net/private/socketowner
import std/oserrors
import zal_net/rt
import zal_net/rt/cancel
import zal_net/errors
import zal_net/private/core/iocancel
import zal_net/raw/io
import zal_net/private/sys/posix
import zal_net/private/core/waitq
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/net/address
import zal_net/raw/fdops
import zal_net/private/sys/sock

export Shutdown, DefaultTimeoutMs


type
  UnixStream* = object
    socket: SocketOwner
    timeoutMs*: int

  UnixListener* = object
    socket: SocketOwner
    path*: string
    error*: string

  UnixDatagram* = object
    socket: SocketOwner
    timeoutMs*: int
    path*: string                ## bound path (removed on close), or ""
    error*: string

  UnixStreamPtr* = ptr UnixStream
  UnixListenerPtr* = ptr UnixListener
  UnixDatagramPtr* = ptr UnixDatagram

  UnixHandler* = proc (s: UnixStreamPtr): int {.nimcall, passive.}

when defined(windows):
  proc cUnlink(path: cstring): cint {.importc: "_unlink", header: "<io.h>".}
else:
  proc cUnlink(path: cstring): cint {.importc: "unlink", header: "<unistd.h>".}

const AfUnix = 1.cint

proc fd(s: UnixStream): cint {.inline.} = handle(s.socket)
proc fd(s: UnixStreamPtr): cint {.inline.} = handle(s.socket)
proc fd(l: UnixListener): cint {.inline.} = handle(l.socket)
proc fd(u: UnixDatagram): cint {.inline.} = handle(u.socket)

proc takeUnix*(s: UnixStreamPtr): UnixStream =
  ## Transfer only while no operation borrows this stream.
  result = s[]
  s.socket = default(SocketOwner)

proc adoptUnix*(s: UnixStreamPtr; descriptor: var cint; timeoutMs = DefaultTimeoutMs): bool =
  if fd(s) >= 0 or descriptor < 0: return false
  s.socket = ownedSocket(descriptor)
  s.timeoutMs = timeoutMs
  descriptor = -1
  result = true

proc takeNativeHandle*(s: UnixStreamPtr): cint = takeHandle(s.socket)

proc isOpen*(s: UnixStream): bool {.inline.} = s.fd >= 0
proc nativeHandle*(s: UnixStream): cint {.inline.} = s.fd
proc nativeHandle*(s: UnixStreamPtr): cint {.inline.} = s.fd
proc ok*(l: UnixListener): bool {.inline.} = l.fd >= 0
proc ok*(u: UnixDatagram): bool {.inline.} = u.fd >= 0
proc nativeHandle*(l: UnixListener): cint {.inline.} = l.fd
proc nativeHandle*(u: UnixDatagram): cint {.inline.} = u.fd

proc unlinkPath(path: string) =
  if path.len > 0 and path[0] != '@':   # abstract names have no file
    var p = path
    discard cUnlink(p.toCString)

# ------------------------------------------------------------------ streams

proc connectUnixInto*(stream: UnixStreamPtr; path: string; timeoutMs = 10_000;
                      streamTimeoutMs = DefaultTimeoutMs;
                      tok: nil CancelToken = nil; deadline = never): int {.passive.} =
  ## Open a closed stable owner; failure preserves it and its timeout setting.
  if isOpen(stream[]): return ResourceBusy
  retain(tok)
  defer: release(tok)
  if cancelled(tok): return ECancelled
  if stopping(): return ResourceClosed
  let a = unixAddress(path)
  if not isValid(a): return InvalidInput
  let endAt = earlier(deadline, afterMs(timeoutMs))
  if monoNow() >= endAt: return IoTimedOut
  let fd = sockSocket(AfUnix, SOCK_STREAM, 0)
  if fd < 0: return -int(osLastError())
  setNonblock(fd)
  if sockConnect(fd, unsafeAddr a.raw.ss, a.raw.len) != 0:
    let err = int(osLastError())
    if err != EInProgress and err != EAgain:
      discard closeRaw(fd)
      return -err
    var code = 0
    parkConnectOutcome(fd, endAt, tok, code)
    if code != 0:
      closeFd(fd)
      return code
  if cancelled(tok) or stopping():
    closeFd(fd)
    return (if cancelled(tok): ECancelled else: ResourceClosed)
  stream.socket = ownedSocket(fd)
  stream.timeoutMs = streamTimeoutMs
  result = 0

template connectUnix*(path: string; timeoutMs = 10_000;
                      streamTimeoutMs = DefaultTimeoutMs;
                      tok: nil CancelToken = nil; deadline: Deadline = never): UnixStream =
  block:
    let name = path
    var owner = default(UnixStream)
    discard connectUnixInto(addr owner, name, timeoutMs, streamTimeoutMs, tok, deadline)
    owner

proc takeUnixListener*(listener: UnixListenerPtr): UnixListener =
  ## Transfer only with no raw accept/serve operation borrowing this listener.
  result = listener[]
  listener.socket = default(SocketOwner)
  listener.path = ""
  listener.error = ""

proc listenUnixInto*(owner: UnixListenerPtr; path: string; backlog = 1024): int =
  ## Open a closed stable owner. Failure preserves its fields and native errors.
  ## The existing path policy replaces stale files and removes owned paths on close.
  if owner[].ok: return ResourceBusy
  if stopping(): return ResourceClosed
  if backlog <= 0 or backlog > int(high(cint)): return InvalidInput
  let a = unixAddress(path)
  if not isValid(a): return InvalidInput
  let probe = sockSocket(AfUnix, SOCK_STREAM, 0)
  if probe < 0: return -int(osLastError())
  if not sockNonblock(probe):
    let code = -int(osLastError())
    discard closeRaw(probe)
    return code
  let connected = sockConnect(probe, unsafeAddr a.raw.ss, a.raw.len)
  let probeError = if connected == 0: 0 else: int(osLastError())
  discard closeRaw(probe)
  if connected == 0 or probeError == EInProgress or probeError == EAgain:
    return ResourceBusy
  if probeError != ENoEntry and probeError != EConnRefused and probeError != ENotSocket:
    return -probeError
  unlinkPath(path)
  let fd = sockSocket(AfUnix, SOCK_STREAM, 0)
  if fd < 0: return -int(osLastError())
  if sockBind(fd, unsafeAddr a.raw.ss, a.raw.len) != 0:
    let code = -int(osLastError())
    discard closeRaw(fd)
    return code
  if sockListen(fd, cint(backlog)) != 0 or not sockNonblock(fd):
    let code = -int(osLastError())
    discard closeRaw(fd)
    unlinkPath(path)
    return code
  installStopHandlers()
  if not registerListener(fd):
    discard closeRaw(fd)
    unlinkPath(path)
    return QueueFull
  owner.socket = ownedSocket(fd)
  owner.path = path
  owner.error = ""
  result = 0

proc listenUnix*(path: string; backlog = 1024): UnixListener =
  ## Value convenience; use listenUnixInto for the exact numeric error.
  result = default(UnixListener)
  let code = listenUnixInto(addr result, path, backlog)
  if code != 0: result.error = errors.describe(code)

proc acceptUnixInto*(stream: UnixStreamPtr; listener: UnixListenerPtr;
                     streamTimeoutMs = DefaultTimeoutMs;
                     deadline: Deadline = never; tok: nil CancelToken = nil): int {.passive.} =
  ## A cancelled wait preserves the listener. Failure preserves the output owner.
  ## Both owners stay stable until completion; one accept per listener per loop.
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

template accept*(l: UnixListener; streamTimeoutMs = DefaultTimeoutMs;
                 deadline: Deadline = never; tok: nil CancelToken = nil): UnixStream =
  block:
    var listener = l                # borrowed descriptor; not a second owner
    var stream = default(UnixStream)
    discard acceptUnixInto(addr stream, addr listener, streamTimeoutMs, deadline, tok)
    stream

proc runHandler(fd: cint; h: UnixHandler; timeoutMs: int) {.passive.} =
  var s = UnixStream(socket: ownedSocket(fd), timeoutMs: timeoutMs)
  discard h(addr s)
  if s.fd >= 0: closeFd(s.fd)

proc acceptLoop(fd: cint; h: UnixHandler; timeoutMs: int) {.passive.} =
  while true:
    let c = waitAccept(fd)
    if c < 0: break
    if not tryStartConn(runHandler(cint(c), h, timeoutMs)):
      closeFd(cint(c))
      break

proc serve*(l: UnixListener; h: UnixHandler; streamTimeoutMs = DefaultTimeoutMs) =
  if l.fd >= 0: spawnTask acceptLoop(l.fd, h, streamTimeoutMs)

proc close*(l: var UnixListener): bool {.passive.} =
  ## Stop the accept loops, close, remove the socket file.
  if l.fd < 0: return true
  result = closeListener(l.fd) == wrReady
  if result:
    discard takeHandle(l.socket)
    unlinkPath(l.path)
    l.path = ""

proc closeNow*(l: var UnixListener) =
  ## Quiescent only, with no accept loops or pending accepts. Does not bypass
  ## an already-started asynchronous close acknowledgement protocol.
  if l.fd >= 0 and unregisterIdleListener(l.fd):
    closeFd(takeHandle(l.socket))
    unlinkPath(l.path)
    l.path = ""

proc recvInto*(s: UnixStreamPtr; p: pointer; n: int; deadline = never; tok: nil CancelToken = nil): int {.passive.} =
  result = fdRecv(s.fd, s.timeoutMs, p, n, deadline, tok)
proc sendFrom*(s: UnixStreamPtr; p: pointer; n: int; deadline = never; tok: nil CancelToken = nil): int {.passive.} =
  result = fdSend(s.fd, s.timeoutMs, p, n, deadline, tok)
proc recvVectored*(s: UnixStreamPtr; iov: ptr IoVec; count: int; deadline = never; tok: nil CancelToken = nil): int {.passive.} =
  result = fdRecvv(s.fd, s.timeoutMs, iov, count, deadline, tok)
proc sendVectored*(s: UnixStreamPtr; iov: ptr IoVec; count: int; deadline = never; tok: nil CancelToken = nil): int {.passive.} =
  result = fdSendv(s.fd, s.timeoutMs, iov, count, deadline, tok)
proc readExactly*(s: UnixStreamPtr; p: pointer; n: int; deadline = never; tok: nil CancelToken = nil): bool {.passive.} =
  result = fdReadExactly(s.fd, s.timeoutMs, p, n, deadline, tok)
proc writeAll*(s: UnixStreamPtr; p: pointer; n: int; deadline = never; tok: nil CancelToken = nil): bool {.passive.} =
  result = fdWriteAll(s.fd, s.timeoutMs, p, n, deadline, tok)
proc write*(s: UnixStreamPtr; data: string; deadline = never; tok: nil CancelToken = nil): bool {.passive.} =
  var bytes = data
  result = bytes.len == 0 or fdWriteAll(s.fd, s.timeoutMs, cast[pointer](bytes.toCString), bytes.len, deadline, tok)
proc shutdown*(s: UnixStreamPtr; how = shutWrite) = fdShutdown(s.fd, ord(how))
proc shutdownWrite*(s: UnixStreamPtr) = fdShutdown(s.fd, 1)
proc interrupt*(s: UnixStreamPtr) =
  ## Wake whatever is parked on the stream and fail what follows.
  fdShutdown(s.fd, 2)
proc localAddress*(s: UnixStream): SocketAddress = fdLocal(s.fd)
proc remoteAddress*(s: UnixStream): SocketAddress = fdRemote(s.fd)
proc close*(s: UnixStreamPtr) =
  if s.fd >= 0:
    closeFd(takeHandle(s.socket))

template recvInto*(s: UnixStreamPtr; buf: var openArray[byte]; deadline: Deadline =
  never; tok: nil CancelToken = nil): int = recvInto(s, dataPtr(buf), buf.len, deadline, tok)

template sendFrom*(s: UnixStreamPtr; buf: openArray[byte]; deadline: Deadline =
  never; tok: nil CancelToken = nil): int = sendFrom(s, dataPtr(buf), buf.len, deadline, tok)

template recv*(s: UnixStreamPtr; buf: var openArray[byte]; deadline: Deadline =
  never; tok: nil CancelToken = nil): int = recvInto(s, buf, deadline, tok)

template send*(s: UnixStreamPtr; buf: openArray[byte]; deadline: Deadline =
  never; tok: nil CancelToken = nil): int = sendFrom(s, buf, deadline, tok)

template readExactly*(s: UnixStreamPtr; buf: var openArray[byte]; deadline: Deadline =
  never; tok: nil CancelToken = nil): bool = readExactly(s, dataPtr(buf), buf.len, deadline, tok)

template writeAll*(s: UnixStreamPtr; buf: openArray[byte]; deadline: Deadline =
  never; tok: nil CancelToken = nil): bool = writeAll(s, dataPtr(buf), buf.len, deadline, tok)


# ---------------------------------------------------------------- datagrams

proc bindUnixDatagram*(path: string; timeoutMs = DefaultTimeoutMs): UnixDatagram =
  ## A datagram socket bound to `path` (an existing file is replaced).
  result = UnixDatagram(socket: ownedSocket(-1), timeoutMs: timeoutMs, path: path)
  let a = unixAddress(path)
  if not isValid(a):
    result.error = "socket path empty or longer than 103 bytes"
    return
  unlinkPath(path)
  let fd = sockSocket(AfUnix, SOCK_DGRAM, 0)
  if fd < 0 or sockBind(fd, unsafeAddr a.raw.ss, a.raw.len) != 0:
    result.error = path & ": bind failed (errno " & $int(osLastError()) & ")"
    if fd >= 0: discard closeRaw(fd)
    return
  setNonblock(fd)
  result.socket = ownedSocket(fd)

proc sendTo*(u: UnixDatagram; p: pointer; n: int; to: SocketAddress; deadline = never; tok: nil CancelToken = nil): int {.passive.} =
  result = fdSendTo(u.fd, AfUnix, u.timeoutMs, p, n, to, deadline, tok)

proc recvFrom*(u: UnixDatagram; p: pointer; n: int; src: nil ptr SocketAddress = nil; deadline = never; tok: nil CancelToken = nil): int {.passive.} =
  result = fdRecvFrom(u.fd, u.timeoutMs, p, n, src, deadline, tok)

proc close*(u: var UnixDatagram) =
  if u.fd >= 0:
    closeFd(takeHandle(u.socket))
  unlinkPath(u.path)
  u.path = ""

template sendTo*(u: UnixDatagram; buf: openArray[byte]; to: SocketAddress;
                 deadline: Deadline = never; tok: nil CancelToken = nil): int =
  sendTo(u, dataPtr(buf), buf.len, to, deadline, tok)

template recvFrom*(u: UnixDatagram; buf: var openArray[byte]; src: var SocketAddress;
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  recvFrom(u, dataPtr(buf), buf.len, addr src, deadline, tok)
