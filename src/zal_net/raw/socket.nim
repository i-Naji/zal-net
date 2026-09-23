import zal_net/private/runtime
## Socket options, non-blocking helpers, listening (dual-stack, tuned), the
## listener registry shut down on SIGTERM/SIGINT, and non-blocking connect.

import std/oserrors
import std/atomics
import zal_net/rt
import zal_net/raw/io
import zal_net/private/core/waitq
import zal_net/private/sys/sock
import zal_net/private/sys/types
import zal_net/net/sockaddr
import zal_net/errors
import zal_net/private/sys/resolvererror
from zal_net/private/sys/posix import ignoreSigpipe, EIntr
export ignoreSigpipe   # initRuntime calls it; kept for programs that write earlier

const
  SockBuf = (when defined(windows): 0 else: 1 shl 20)
    ## One read should be able to hold several 64 KB records. The kernel
    ## doubles the requested size on Darwin. Windows sizes its buffers
    ## itself, and setting them turns that off.

type
  ListenResult* = object
    ok*: bool
    fd*: cint
    msg*: string
    code*: int                    ## zero success; negative native/library error



when not defined(windows):
  type
    Sigaction {.importc: "struct sigaction", header: "<signal.h>".} = object
      sa_handler: nil pointer          # SIG_DFL is 0
      sa_mask: array[16, uint64]
      sa_flags: cint
      sa_restorer: nil pointer

    SignalHandler = proc (sig: cint) {.noconv.}

    HandlerAction {.importc: "struct sigaction", header: "<signal.h>".} = object
      sa_handler: nil SignalHandler    # SIG_DFL is 0

  proc sigaction(sig: cint; act: pointer; old: nil pointer): cint {.importc, header: "<signal.h>".}
  proc raiseSignal(sig: cint): cint {.importc: "raise", header: "<signal.h>".}

template socket(af, kind, proto: cint): cint = sockSocket(af, kind, proto)
template bindSocket(fd: cint; sa: pointer; len: cuint): cint = sockBind(fd, sa, len)
template listenSocket(fd, backlog: cint): cint = sockListen(fd, backlog)
template connectSocket(fd: cint; sa: pointer; len: cuint): cint = sockConnect(fd, sa, len)
template setsockopt(fd, level, opt: cint; v: pointer; len: cuint): cint = sockSetsockopt(fd, level, opt, v, len)
template getsockopt(fd, level, opt: cint; v: pointer; len: ptr cuint): cint = sockGetsockopt(fd, level, opt, v, len)
template shutdownRaw(fd, how: cint): cint = sockShutdown(fd, how)
proc closeRaw*(fd: cint): cint {.inline.} = sockClose(fd)


proc socketError*(fd: cint): cint =
  var err: cint = 0
  var len = cuint(sizeof(err))
  if getsockopt(fd, SOL_SOCKET, SO_ERROR, addr err, addr len) != 0:
    return -1
  result = err

proc setIntOpt*(fd, level, opt: cint; v: cint) {.inline.} =
  var x = v
  discard setsockopt(fd, level, opt, addr x, cuint(sizeof(x)))

proc setReuse(fd, sockType: cint; reusePort: bool) =
  ## SO_REUSEADDR for TCP only: rebinding a port with connections in
  ## TIME_WAIT. On a UDP socket, Linux would let other sockets bind the
  ## same port (even an automatic one), splitting its datagrams between
  ## them. SO_REUSEPORT only when asked: that sharing is then the point.
  ## Windows needs neither to rebind a listener, and its SO_REUSEADDR would
  ## let another socket take the port: nothing is set there.
  when not defined(windows):
    if sockType == SOCK_STREAM: setIntOpt(fd, SOL_SOCKET, SO_REUSEADDR, 1)
    if reusePort: setIntOpt(fd, SOL_SOCKET, SO_REUSEPORT, 1)

proc setV6only*(fd: cint; on: cint) =
  setIntOpt(fd, IPPROTO_IPV6, IPV6_V6ONLY, on)

proc setNonblock*(fd: cint) = discard sockSetNonblock(fd, true)

proc setBlocking*(fd: cint) = discard sockSetNonblock(fd, false)

proc openPair*(): (cint, cint) =
  ## Connected byte pipe. Both ends are non-blocking.
  result = (-1.cint, -1.cint)
  var sv = default(array[2, cint])
  if sockPair(addr sv[0]) != 0: return
  setNonblock(sv[0])
  setNonblock(sv[1])
  result = (sv[0], sv[1])

proc tuneTcp*(fd: cint; noDelay: bool) =
  ## Nagle and socket buffer sizes. Applied to listeners (accepted sockets
  ## inherit them on Darwin/BSD) and to outgoing sockets before connect, so
  ## the SYN advertises a window scale that matches the buffer.
  if noDelay: setIntOpt(fd, IPPROTO_TCP, TCP_NODELAY, 1)
  when SockBuf > 0:
    setIntOpt(fd, SOL_SOCKET, SO_SNDBUF, cint(SockBuf))
    setIntOpt(fd, SOL_SOCKET, SO_RCVBUF, cint(SockBuf))

proc setNoDelay*(fd: cint) =
  tuneTcp(fd, true)

proc tuneAccepted*(fd: cint; noDelay: bool) {.inline.} =
  ## Darwin/BSD accepted sockets inherit TCP_NODELAY and buffer sizes from
  ## the tuned listener; Linux inherits the buffers but not Nagle.
  when defined(linux):
    if noDelay: setIntOpt(fd, IPPROTO_TCP, TCP_NODELAY, 1)
  else:
    discard fd
    discard noDelay

# Listening sockets are shut down on SIGTERM/SIGINT before the process dies.
# With io_uring the kernel tears a ring down asynchronously after exit, and a
# poll still armed on a listener keeps the socket completing handshakes for
# a few milliseconds: clients were accepted and then reset, and a restarted
# server could not bind. shutdown(2) takes the socket out of LISTEN at once.
var gStopInstalled: int

proc closeListeners() =
  var i = 0
  while i < MaxListeners:
    let fd = listenerFd(i)
    if fd >= 0:
      discard shutdownRaw(fd, 2.cint)
      discard closeRaw(fd)
    i = i + 1

when defined(windows):
  proc onStopSignal(sig: cint): cint {.noconv.} =
    ## A console event, on a thread of its own; the process ends after.
    closeListeners()
    result = 0
else:
  proc onStopSignal(sig: cint) {.noconv.} =
    ## Async-signal-safe: plain syscalls on a fixed array, then the default
    ## action, so the exit status is unchanged.
    closeListeners()
    var sa {.noinit.}: Sigaction
    zeroMem(addr sa, sizeof(sa))
    discard sigaction(sig, addr sa, nil) # SIG_DFL
    discard raiseSignal(sig)

proc installStopHandlers*() =
  ## Idempotent; `initLoop` calls it. Windows: console control events.
  var expected = 0
  if not atomicCompareExchange(gStopInstalled, expected, 1): return
  when defined(windows):
    discard onConsoleCtrl(onStopSignal)
  else:
    var sa {.noinit.}: HandlerAction
    zeroMem(addr sa, sizeof(Sigaction))
    sa.sa_handler = onStopSignal
    discard sigaction(SIGTERM, addr sa, nil)
    discard sigaction(SIGINT, addr sa, nil)

proc interruptSocket*(fd: cint) =
  if fd >= 0: discard shutdownRaw(fd, 2.cint)

proc shutdownWrite*(fd: cint) =
  if fd >= 0: discard shutdownRaw(fd, SHUT_WR)

proc shutdownRead*(fd: cint) =
  ## Wake whatever reads `fd` (it reads the end) without a packet to the peer.
  if fd >= 0: discard shutdownRaw(fd, 0.cint)

proc setResetOnClose*(fd: cint) =
  if fd < 0: return
  var lin {.noinit.}: Linger
  lin.l_onoff = 1
  lin.l_linger = 0
  discard setsockopt(fd, SOL_SOCKET, SO_LINGER, addr lin, cuint(sizeof(lin)))

proc abortSocket*(fd: cint): bool =
  ## Reset a TCP connection now (SO_LINGER 0, then a disconnect), waking
  ## every task parked on it; the descriptor stays open until closed. False
  ## where the system cannot (Windows, a kTLS socket): it resets when closed.
  if fd < 0: return false
  setResetOnClose(fd)
  result = sockAbort(fd)

proc lingerRst*(fd: cint) =
  setResetOnClose(fd)
  closeFd(fd)

proc listenError*(r: ListenResult; port: uint16): string =
  "listen " & $port & ": " & r.msg

# ---------------------------------------------------------------- addresses

# ------------------------------------------------------------------- listen

proc bindAny(fd: cint; port: uint16; v6: bool): bool =
  var sa = default(SockAddrBuf)
  var zero = default(array[16, byte])
  if v6: discard setIpAddr(sa, zero, port, AF_INET6)
  else: discard setIpAddr(sa, zero.toOpenArray(0, 3), port, AF_INET)
  result = bindSocket(fd, addr sa.ss, sa.len) == 0

proc tryListen(port: uint16; sockType: cint; backlog: int; bindAddr: string;
               noDelay, reusePort: bool): ListenResult =
  result = default(ListenResult)
  result.fd = -1
  result.code = DnsNoAddresses
  if sockType == SOCK_STREAM and (backlog <= 0 or backlog > int(high(cint))):
    result.msg = "invalid backlog"
    result.code = InvalidInput
    return
  if bindAddr.len > 255:
    result.msg = "invalid bind address"
    result.code = InvalidInput
    return
  for ch in bindAddr:
    if ch == '\0':
      result.msg = "invalid bind address"
      result.code = InvalidInput
      return
  var fd: cint = -1
  if bindAddr.len > 0:
    var hints = default(AddrInfo)
    hints.ai_socktype = sockType
    hints.ai_flags = AI_PASSIVE
    var res: AddrInfoList = nil
    var node = bindAddr
    var service = $port
    let err = getaddrinfo(node.toCString, service.toCString, addr hints, addr res)
    if err != 0:
      result.code = resolverFailure(err)
      result.msg = fromCString(gai_strerror(err))
      return
    if res == nil:
      result.msg = "no bind addresses"
      return
    var next: AddrInfoList = res
    while true:
      let ai = next
      if ai == nil: break
      next = ai.ai_next
      let sa = ai.ai_addr
      if sa == nil: continue
      fd = socket(ai.ai_family, sockType, 0)
      if fd >= 0:
        setReuse(fd, sockType, reusePort)
        if ai.ai_family == AF_INET6: setV6only(fd, 0)
        if bindSocket(fd, sa, ai.ai_addrlen) == 0: break
        result.code = -int(osLastError())
        discard closeRaw(fd)
        fd = -1
      else:
        result.code = -int(osLastError())
    freeaddrinfo(res)
  else:
    fd = socket(AF_INET6, sockType, 0)
    let v6 = fd >= 0
    if fd < 0: fd = socket(AF_INET, sockType, 0)
    if fd >= 0:
      setReuse(fd, sockType, reusePort)
      if v6: setV6only(fd, 0)
      if not bindAny(fd, port, v6):
        result.code = -int(osLastError())
        discard closeRaw(fd)
        fd = -1
    else:
      result.code = -int(osLastError())
  if fd < 0:
    result.msg = "socket or bind"
    return
  if sockType == SOCK_STREAM:
    tuneTcp(fd, noDelay)
    if listenSocket(fd, cint(backlog)) != 0:
      result.code = -int(osLastError())
      discard closeRaw(fd)
      result.msg = "listen"
      return
    installStopHandlers()
    if not registerListener(fd):
      result.code = QueueFull
      discard closeRaw(fd)
      result.msg = "listener registry full"
      return
  if sockType == SOCK_DGRAM:
    setIntOpt(fd, SOL_SOCKET, SO_RCVBUF, cint(4 * 1024 * 1024))
    setIntOpt(fd, SOL_SOCKET, SO_SNDBUF, cint(4 * 1024 * 1024))
  if not sockSetNonblock(fd, true):
    result.code = -int(osLastError())
    if sockType == SOCK_STREAM: discard unregisterIdleListener(fd)
    discard closeRaw(fd)
    result.msg = "nonblocking socket"
    return
  result.ok = true
  result.fd = fd
  result.code = 0

proc tryListenTcp*(port: uint16; backlog = 4096; bindAddr = ""; noDelay = true; reusePort = false): ListenResult =
  tryListen(port, SOCK_STREAM, backlog, bindAddr, noDelay, reusePort)

proc tryListenUdp*(port: uint16; bindAddr = ""; reusePort = false): ListenResult =
  tryListen(port, SOCK_DGRAM, 0, bindAddr, false, reusePort)

proc openUdpSocket*(family: var cint; error: nil ptr int = nil): cint =
  ## Nonblocking dual-stack socket, with IPv4 fallback. Failure owns nothing;
  ## the optional error receives the native failure before cleanup overwrites it.
  if error != nil: error[] = 0
  family = AF_INET6
  result = socket(AF_INET6, SOCK_DGRAM, 0)
  if result >= 0:
    setV6only(result, 0)
  else:
    family = AF_INET
    result = socket(AF_INET, SOCK_DGRAM, 0)
  if result < 0:
    if error != nil: error[] = -int(osLastError())
  elif not sockSetNonblock(result, true):
    let code = -int(osLastError())
    discard closeRaw(result)
    result = -1
    if error != nil: error[] = code

# --------------------------------------------------------------------- dial

proc startConnect*(sa: ptr SockAddrBuf; noDelay: bool; pending: var bool;
                   error: var int): cint =
  ## Non-blocking socket, tuned before the SYN, connect started.
  pending = false
  error = 0
  let fd = socket(cint(sa.ss.ss_family), SOCK_STREAM, 0)
  if fd < 0:
    error = -int(osLastError())
    return -1
  # An IPv4-mapped address needs a dual-stack socket: Windows makes IPv6
  # sockets IPv6-only by default (Linux and macOS do not).
  if cint(sa.ss.ss_family) == AF_INET6: setV6only(fd, 0)
  setNonblock(fd)
  tuneTcp(fd, noDelay)
  while true:
    if connectSocket(fd, addr sa.ss, sa.len) == 0: return fd
    let err = int(osLastError())
    if err == EIntr: continue
    if err == EInProgress:
      pending = true
      return fd
    error = -err                 # close must not overwrite the failing errno
    discard closeRaw(fd)
    return -1

proc startConnect*(sa: ptr SockAddrBuf; noDelay: bool; pending: var bool): cint =
  var error = 0
  result = startConnect(sa, noDelay, pending, error)

template getsockname(fd: cint; sa: pointer; len: ptr cuint): cint = sockGetsockname(fd, sa, len)

proc localPort*(fd: cint): uint16 =
  ## The port a socket is bound to, or 0.
  result = 0
  var sa = default(SockAddrBuf)
  sa.len = cuint(sizeof(SockaddrStorage))
  if getsockname(fd, addr sa.ss, addr sa.len) != 0: return
  let b = cast[ptr UncheckedArray[byte]](addr sa.ss)
  result = (uint16(b[2]) shl 8) or uint16(b[3])

proc bindEphemeral*(fd, family: cint): uint16 =
  ## Bind `fd` to a port the kernel picks, on every address of `family`;
  ## the port, or 0.
  result = 0
  if bindAny(fd, 0, family == AF_INET6): result = localPort(fd)

proc pokeListener(fd: cint): cint =
  ## One throwaway loopback connection: a pending connection wakes every
  ## poller watching the listener, on every platform. Returns the client
  ## socket, or -1.
  result = -1
  var sa = default(SockAddrBuf)
  sa.len = cuint(sizeof(SockaddrStorage))
  if getsockname(fd, addr sa.ss, addr sa.len) != 0: return
  if cint(sa.ss.ss_family) == 1.cint:        # AF_UNIX: connect to its own path
    let u = socket(1.cint, SOCK_STREAM, 0)
    if u >= 0:
      setNonblock(u)
      discard connectSocket(u, addr sa.ss, sa.len)
    return u
  var loop = default(SockAddrBuf)
  let port = (uint16(cast[ptr UncheckedArray[byte]](addr sa.ss)[2]) shl 8) or
             uint16(cast[ptr UncheckedArray[byte]](addr sa.ss)[3])
  if cint(sa.ss.ss_family) == AF_INET6:
    var ip = default(array[16, byte])
    ip[15] = 1
    discard setIpAddr(loop, ip, port, AF_INET6)
  else:
    let ip = [byte 127, 0, 0, 1]
    discard setIpAddr(loop, ip, port, AF_INET)
  var pending = false
  # Left open: closed at once, the handshake may never reach the accept
  # queue. One descriptor per listener, for the rest of the process.
  let c = startConnect(addr loop, false, pending)
  result = c
  if c >= 0 and pending:
    # Let the connection reach the accept queue before the caller shuts
    # the listener down; a refused one wakes nothing on some backends.
    var p = PollFd(fd: c, events: PollOut, revents: 0)
    discard sockPoll(addr p, 1, 100)

proc stopAccepting*() =
  ## Stop every accept loop on the registered listeners: `acceptNow`
  ## returns AcceptClosed from now on, and parked accept loops are woken to
  ## see it. On the loops backend the listeners are also shut down (Linux
  ## then refuses new connections). The descriptors stay open until the
  ## process exits, so no loop's registration goes stale. It may block the
  ## caller for up to 100 ms per listener while the wake connection
  ## completes.
  markAcceptStopped()
  var i = 0
  while i < MaxListeners:
    let fd = listenerFd(i)
    if fd >= 0:
      discard pokeListener(fd)
      beWakeAcceptors(fd)
    i = i + 1

proc closeListener*(fd: cint; acceptors = 1;
                    deadline = afterMs(5000)): WaitResult {.passive.} =
  ## Stop the accept loops on listener `fd` and close it, freeing its port.
  ## `acceptors` is how many accept loops run on it (one `spawnAll`: the
  ## default). Waits until each has seen AcceptClosed and no loop still
  ## watches the descriptor, so its number can be reused safely.
  ## wrClosed when `fd` is not a registered listener. wrTimedOut when an
  ## accept loop did not answer by `deadline`: the listener then stays open
  ## and stopped.
  let slot = listenerSlot(fd)
  if slot < 0: return wrClosed
  beginClose(slot, acceptors + beForgetAcks())
  var poke: cint = -1
  if beNeedsPoke(): poke = pokeListener(fd)
  beWakeAcceptors(fd, owedCounter(slot))
  result = wrReady
  while closeOwed(slot) > 0:
    if deadline <= monoNow():
      result = wrTimedOut
      break
    sleepMs(1)
  if result == wrReady:
    # Free the slot first: until the close, the number cannot be reused.
    freeListener(slot)
    discard closeRaw(fd)
  if poke >= 0: discard closeRaw(poke)
