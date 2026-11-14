# A connection: one TCP or Unix-domain stream, its read buffer, its deadline and its stop
# token. The shape follows `std/socket`, so code written against one reads
# like code written against the other.
#
#   var c = connect("example.com", 80, afterMs(5_000))
#   c.write "GET / HTTP/1.0\r\n\r\n"
#   while c.fill() > 0: discard
#   echo c.buffered, " bytes"
#
# The read side has two halves. `fill` puts bytes into the buffer; `peek` and
# `consume` take them out. A parser gets `peek`, a view into the buffer, and
# says how much of it it used. `read` skips the buffer when it is empty and
# reads straight into the caller's bytes.
#
# A `Conn` is a value that owns its descriptor. It cannot be copied, moving it
# moves the descriptor, and it closes when it goes out of scope. One task uses
# a `Conn` at a time, and that is why no operation here takes a lock. To move
# bytes between two connections use `zal_net/engine`'s relay; to interrupt a
# connection from another task, cancel its token.
#
# A failure is never in the return value. `fill` and `read` answer how many
# bytes arrived, and 0 means the peer finished, which is an end and not an
# error. Everything else raises an `ErrorCode`: `TimeoutError` when the
# deadline came first, `AbortedOperation` when the token was cancelled.
#
# ## Why the parking operations are templates
#
# `fill`, `read`, `write`, `flush`, `readLine` and `accept` are templates, and
# in `std/socket` they are procedures. A passive procedure gets its own frame,
# and with several workers the runtime hands a chain back to the pool after
# two steps, so a frame per read costs a trip through the pool per read. On a
# loopback echo with four workers that made the procedure form 2.7 times
# slower than this one (880 ms against 330 ms for 20000 round trips). Raising
# the two-step limit fixes the echo and breaks fairness at 1000 connections,
# where runs then collapse to half their rate. So the wait happens in the
# caller's frame, and each template is one loop with no procedure under it
# that can park.

import std/assertions
import zal_net/rt
import zal_net/rt/[cancel, time]
import zal_net/raw/fdops
import zal_net/raw/tcp as rawtcp
import zal_net/raw/unix as rawunix
import zal_net/net/[address, failure]
import zal_net/buffers
import zal_net/errors

export time, cancel.CancelToken, cancel.newCancelToken, cancel.cancel, cancel.cancelled
export address.SocketAddress

const
  ReadChunk* = 8 * 1024
    ## What one `fill` asks the kernel for. Larger than most request heads and
    ## small enough that an idle connection holds little.
  MaxBuffered* = 64 * 1024
    ## The most a `Conn` holds unread. A peer that sends more of something
    ## than this before the parser consumes any of it gets `FullError`: the
    ## alternative is letting the peer choose our memory use.

  SetupLimitMs = 1 shl 30
    ## The raw connect wants an idle limit in milliseconds next to its
    ## deadline. Here the deadline alone decides, so this is twelve days.

type
  Conn* = object
    fd: cint
    deadline: Deadline   ## the standing budget; an operation can only tighten it
    stop: nil CancelToken
    rbuf: seq[byte]
    rlen: int            ## bytes held
    rpos: int            ## bytes already consumed from the front
    wbuf: seq[byte]

  Listener* = object
    raw: rawtcp.TcpListener
    local: rawunix.UnixListener   ## the one in use when `isLocal`
    isLocal: bool
    stop: nil CancelToken
    noDelay: bool

proc `=destroy`*(c: Conn) =
  ## The descriptor goes when the value does, so the error path that nobody
  ## wrote cannot leak it. A hand-written destructor replaces the field-wise
  ## one, so the buffers are freed here too.
  if c.fd >= 0:
    releaseFd(c.stop, c.fd)
    closeFd(c.fd)
  release(c.stop)
  `=destroy`(c.rbuf)
  `=destroy`(c.wbuf)

proc `=wasMoved`*(c: var Conn) {.nodestroy, inline.} =
  ## -1 and not the default zero: 0 is stdin, a perfectly good descriptor.
  c.fd = -1
  c.stop = nil
  `=wasMoved`(c.rbuf)
  `=wasMoved`(c.wbuf)

proc `=dup`*(c: Conn): Conn {.error.}

proc `=copy`*(dest: var Conn; src: Conn) {.error.}
  ## Two values over one descriptor are two owners, and whichever dies first
  ## closes it under the other.

proc initConn*(fd: cint; deadline: Deadline; stop: nil CancelToken = nil): Conn =
  ## Take ownership of a connected, non-blocking stream socket. `stop` is the
  ## token of whoever may end this connection (a server, a scope); the `Conn`
  ## gets a child of it, so cancelling the parent ends the connection and
  ## cancelling the connection leaves the parent alone.
  ##
  ## The buffers start empty. The first `fill` or `scratch` allocates one, so
  ## a connection that never speaks costs a descriptor and a token.
  result = Conn(fd: fd, deadline: deadline, stop: newCancelToken(stop),
                rbuf: @[], rlen: 0, rpos: 0, wbuf: @[])
  adoptFd(result.stop, fd)

proc isOpen*(c: Conn): bool {.inline.} = c.fd >= 0

proc nativeHandle*(c: Conn): cint {.inline.} = c.fd
  ## The descriptor, for socket options and for `zal_net/engine`. The `Conn`
  ## still owns it.

proc cancelToken*(c: Conn): nil CancelToken {.inline.} = c.stop
  ## Cancel it from any task to end this connection's waits; the socket is
  ## shut down, so the peer sees the end too.

proc budget*(c: Conn; dl: Deadline): Deadline {.inline.} =
  ## The deadline an operation runs under: the connection's, or a tighter one
  ## from the caller. A caller cannot widen it.
  earlier(c.deadline, dl)

proc renew*(c: var Conn; deadline: Deadline) {.inline.} =
  ## Start a fresh budget. A kept-alive connection serves many exchanges, and
  ## each needs its own or the first spends the allowance of all of them.
  c.deadline = deadline

proc close*(c: var Conn) =
  ## Close now and not at the end of the scope. Calling it twice is fine.
  if c.fd >= 0:
    releaseFd(c.stop, c.fd)
    closeFd(c.fd)
    c.fd = -1

proc shutdownWrite*(c: Conn) =
  ## Send FIN and keep reading: the half-close a request/response protocol
  ## uses to say "that was everything".
  if c.fd >= 0: fdShutdown(c.fd, 1)

proc localAddress*(c: Conn): SocketAddress = fdLocal(c.fd)
proc remoteAddress*(c: Conn): SocketAddress = fdRemote(c.fd)

# --------------------------------------------------------- the read side ---

proc buffered*(c: Conn): int {.inline.} =
  ## Bytes read and not yet consumed.
  c.rlen - c.rpos

proc peek*(c: Conn): openArray[byte] =
  ## The unconsumed bytes as a view into the buffer. The parser neither copies
  ## nor owns them, and what it leaves stays for the next `fill` to extend.
  toOpenArray(c.rbuf, c.rpos, c.rlen - 1)

proc consume*(c: var Conn; n: int) {.inline.} =
  ## Drop the first `n` bytes of `peek`.
  assert n >= 0 and n <= c.buffered, "consume past what is buffered"
  c.rpos += n
  if c.rpos == c.rlen:
    # Empty: the next fill starts at the front without moving anything.
    c.rpos = 0
    c.rlen = 0

proc fillRoom*(c: var Conn): int {.raises.} =
  ## Make room for one `fill` and say how much. Moves the unconsumed tail to
  ## the front first, then grows up to `MaxBuffered`. Exported for `fill`.
  if c.rpos > 0:
    let n = c.rlen - c.rpos
    for i in 0 ..< n:
      # Through a local: one element of a seq assigned from another is an
      # alias of the same object, which the compiler refuses.
      let b = c.rbuf[c.rpos + i]
      c.rbuf[i] = b
    c.rlen = n
    c.rpos = 0
  if c.rbuf.len - c.rlen < ReadChunk and c.rbuf.len < MaxBuffered:
    c.rbuf.setLen(min(MaxBuffered, max(c.rbuf.len * 2, ReadChunk)))
  result = c.rbuf.len - c.rlen
  if result == 0: raise FullError

proc fillTarget*(c: var Conn): pointer {.inline.} = addr c.rbuf[c.rlen]
proc filled*(c: var Conn; n: int) {.inline.} = c.rlen += n

template fill*(c: var Conn; dl: Deadline = never): int =
  ## One read into the buffer: the bytes added, or 0 when the peer finished.
  ## Raises `FullError` when `MaxBuffered` bytes sit unconsumed.
  block:
    let room = fillRoom(c)
    var got = 0
    fdRecvInline(c.nativeHandle, 0, fillTarget(c), room, budget(c, dl), got, nil, cancelToken(c))
    checkIo(got)
    filled(c, got)
    got

proc take*(c: var Conn; dest: var openArray[byte]): int =
  ## Copy buffered bytes out, as many as fit. No I/O.
  result = min(dest.len, c.buffered)
  if result > 0:
    copyMem(addr dest[0], addr c.rbuf[c.rpos], result)
    consume(c, result)

template read*(c: var Conn; dest: var openArray[byte]; dl: Deadline = never): int =
  ## Up to `dest.len` bytes: buffered ones first, otherwise one read straight
  ## into `dest`. 0 when the peer finished.
  block:
    var got = take(c, dest)
    if got == 0 and dest.len > 0:
      fdRecvInline(c.nativeHandle, 0, addr dest[0], dest.len, budget(c, dl), got, nil, cancelToken(c))
      checkIo(got)
    got

proc takeLine*(c: var Conn; line: var string; final: bool): bool =
  ## Move one line out of the buffer, without its LF or CRLF. False when no
  ## line end is buffered yet; with `final`, whatever is left is the line.
  result = false
  var i = c.rpos
  while i < c.rlen and c.rbuf[i] != byte('\n'): inc i
  if i < c.rlen or (final and c.buffered > 0):
    var last = i
    if last > c.rpos and i < c.rlen and c.rbuf[last - 1] == byte('\r'): dec last
    for k in c.rpos ..< last: line.add char(c.rbuf[k])
    consume(c, min(i + 1, c.rlen) - c.rpos)
    result = true

template readLine*(c: var Conn; dl: Deadline = never): string =
  ## The next line without its line end. "" at the end of the stream, and also
  ## for an empty line: check `buffered` or use `fill` where that matters.
  ## Raises `FullError` for a line longer than `MaxBuffered`.
  block:
    var line = ""
    while not takeLine(c, line, false):
      if fill(c, dl) == 0:
        discard takeLine(c, line, true)
        break
    line

# -------------------------------------------------------- the write side ---

template writeBytes*(c: var Conn; start: pointer; count: int; dl: Deadline) =
  ## `count` bytes at `start`, all of them or a raise. The loop every write
  ## shares; `start` must stay valid until it returns.
  block:
    let first = start
    let total = count
    let until = budget(c, dl)
    var sent = 0
    while sent < total:
      var k = 0
      fdSendInline(c.nativeHandle, 0, cast[pointer](cast[uint](first) + uint(sent)),
                   total - sent, until, k, nil, cancelToken(c))
      if k == 0: k = NoProgress
      checkIo(k)
      sent += k

template write*(c: var Conn; data: openArray[byte]; dl: Deadline = never) =
  ## All of `data`, or a raise. A short write is the peer's window and not the
  ## caller's business, so this loops.
  block:
    let bytes: openArray[byte] = data
    writeBytes(c, dataPtr(bytes), bytes.len, dl)

template write*(c: var Conn; text: string; dl: Deadline = never) =
  block:
    var held: string = text      # one evaluation, alive across the wait
    writeBytes(c, cast[pointer](held.toCString), held.len, dl)

proc scratch*(c: var Conn; n: int): var openArray[byte] =
  ## `n` bytes of staging the connection keeps between calls. Spell a frame or
  ## a response head into it, then `flush` what was used: one write, no
  ## allocation per message.
  if c.wbuf.len < n: c.wbuf.setLen(n)
  result = toOpenArray(c.wbuf, 0, n - 1)

proc staged*(c: var Conn; n: int): openArray[byte] {.inline.} =
  toOpenArray(c.wbuf, 0, n - 1)

template flush*(c: var Conn; n: int; dl: Deadline = never) =
  ## Send the first `n` bytes of `scratch`.
  block:
    let count = n
    if count > 0: write(c, staged(c, count), dl)

# ------------------------------------------------------ connect and listen ---

proc connect*(host: string; port: uint16; dl: Deadline = never;
              stop: nil CancelToken = nil; noDelay = true): Conn {.passive, raises.} =
  ## Resolve `host` and connect, trying IPv6 and IPv4 addresses in turn the
  ## way Happy Eyeballs describes. `dl` bounds the setup only; the connection
  ## starts with no deadline of its own, so `renew` it before the first
  ## exchange that should be bounded.
  var s = default(rawtcp.TcpStream)
  checkIo(connectInto(addr s, host, port, SetupLimitMs, noDelay, 0, stop, dl))
  result = initConn(rawtcp.takeNativeHandle(addr s), never, stop)

proc connect*(address: SocketAddress; dl: Deadline = never;
              stop: nil CancelToken = nil; noDelay = true): Conn {.passive, raises.} =
  var s = default(rawtcp.TcpStream)
  checkIo(connectInto(addr s, address, SetupLimitMs, noDelay, 0, stop, dl))
  result = initConn(rawtcp.takeNativeHandle(addr s), never, stop)

proc listen*(port: uint16; host = ""; backlog = 1024; stop: nil CancelToken = nil;
             noDelay = true; reusePort = false): Listener {.raises.} =
  ## Listen on `host`, or on every address when it is empty. Port 0 asks the
  ## kernel for one; `port` says which. Connections accepted here get children
  ## of `stop`, so cancelling it ends the accept and every connection.
  result = Listener(raw: default(rawtcp.TcpListener), local: default(rawunix.UnixListener),
                    isLocal: false, stop: stop, noDelay: noDelay)
  retain(stop)
  checkIo(listenInto(addr result.raw, port, host, backlog, noDelay, reusePort))

proc connectUnix*(path: string; dl: Deadline = never;
                  stop: nil CancelToken = nil): Conn {.passive, raises.} =
  ## Connect to the Unix-domain stream socket at `path`. On Linux a path that
  ## starts with `@` names an abstract socket.
  var s = default(rawunix.UnixStream)
  checkIo(connectUnixInto(addr s, path, SetupLimitMs, 0, stop, dl))
  result = initConn(rawunix.takeNativeHandle(addr s), never, stop)

proc listenUnix*(path: string; backlog = 1024; stop: nil CancelToken = nil): Listener {.raises.} =
  ## Listen on a Unix-domain stream socket. A stale socket file at `path` is
  ## replaced, a live one is refused, and `close` removes the file.
  result = Listener(raw: default(rawtcp.TcpListener), local: default(rawunix.UnixListener),
                    isLocal: true, stop: stop, noDelay: false)
  retain(stop)
  checkIo(listenUnixInto(addr result.local, path, backlog))

proc port*(l: Listener): uint16 {.inline.} = rawtcp.port(l.raw)

proc rawListener*(l: var Listener): rawtcp.TcpListenerPtr {.inline.} = addr l.raw
proc localListener*(l: var Listener): rawunix.UnixListenerPtr {.inline.} = addr l.local
proc isLocal*(l: Listener): bool {.inline.} = l.isLocal
  ## True for a Unix-domain listener.
proc stopToken*(l: Listener): nil CancelToken {.inline.} = l.stop
proc tunesNoDelay*(l: Listener): bool {.inline.} = l.noDelay

template accept*(l: var Listener; dl: Deadline = never): Conn =
  ## The next connection. Raises `TimeoutError` at `dl` and `AbortedOperation`
  ## when the listener's token was cancelled.
  block:
    var accepted: cint = -1
    if isLocal(l):
      var s = default(rawunix.UnixStream)
      checkIo(acceptUnixInto(addr s, localListener(l), 0, dl, stopToken(l)))
      accepted = rawunix.takeNativeHandle(addr s)
    else:
      var s = default(rawtcp.TcpStream)
      checkIo(acceptInto(addr s, rawListener(l), 0, tunesNoDelay(l), dl, stopToken(l)))
      accepted = rawtcp.takeNativeHandle(addr s)
    initConn(accepted, never, stopToken(l))

proc close*(l: var Listener) =
  ## Stop listening. The owner calls this while no task waits in `accept`,
  ## which holds because `accept` needs the same `var Listener`.
  if l.isLocal: rawunix.closeNow(l.local)
  else: rawtcp.closeNow(l.raw)
  release(l.stop)
  l.stop = nil
