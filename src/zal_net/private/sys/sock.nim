## Socket system calls, one binding per platform. On POSIX each is the C
## library's own call. On Windows each goes through sys/win/nn_win.c, which
## calls Winsock with the descriptor as a SOCKET and reports failures as
## POSIX errno values (Linux numbering) through osLastError, so callers
## compare against EAGAIN, EINTR... the same way everywhere.
##
## Also here: wake channels (a pipe on POSIX; a loopback UDP socket on
## Windows, where only sockets can be polled), sleeping and the process id.

type
  PollFd* = object          ## struct pollfd
    fd*: cint
    events*: int16
    revents*: int16

const
  MsgPeek* = 2.cint    ## MSG_PEEK has this value on the supported socket platforms
  PollIn* = 1'i16
  PollOut* = 4'i16

import zal_net/net/sockaddr   # on Windows: compiles and links sys/win/*.c

when defined(linux):
  {.compile: "nn_linux.c".}       # fallbacks for old kernels (NN_LINUX_COMPAT=1 forces them)

when defined(windows):
  proc sockSocket*(af, kind, proto: cint): cint {.importc: "nn_sock_socket".}
  proc sockClose*(fd: cint): cint {.importc: "nn_sock_close".}
  proc sockBind*(fd: cint; sa: pointer; len: cuint): cint {.importc: "nn_sock_bind".}
  proc sockConnect*(fd: cint; sa: pointer; len: cuint): cint {.importc: "nn_sock_connect".}
  proc sockListen*(fd, backlog: cint): cint {.importc: "nn_sock_listen".}
  proc sockAccept*(fd: cint; sa: nil pointer; len: nil ptr cuint): cint {.importc: "nn_sock_accept".}
  proc nnSockShutdown(fd, how: cint): cint {.importc: "nn_sock_shutdown".}
  proc sockSetsockopt*(fd, level, opt: cint; v: pointer; len: cuint): cint {.importc: "nn_sock_setsockopt".}
  proc sockGetsockopt*(fd, level, opt: cint; v: pointer; len: ptr cuint): cint {.importc: "nn_sock_getsockopt".}
  proc sockGetsockname*(fd: cint; sa: pointer; len: ptr cuint): cint {.importc: "nn_sock_getsockname".}
  proc sockGetpeername*(fd: cint; sa: pointer; len: ptr cuint): cint {.importc: "nn_sock_getpeername".}
  proc sockRecv*(fd: cint; buf: pointer; n: csize_t; flags: cint): int {.importc: "nn_sock_recv".}
  proc sockSend*(fd: cint; buf: pointer; n: csize_t; flags: cint): int {.importc: "nn_sock_send".}
  proc sockRecvfrom*(fd: cint; buf: pointer; n: csize_t; flags: cint; sa: nil pointer; len: nil ptr cuint): int {.importc: "nn_sock_recvfrom".}
  proc sockSendto*(fd: cint; buf: pointer; n: csize_t; flags: cint; sa: pointer; len: cuint): int {.importc: "nn_sock_sendto".}
  proc sockRead*(fd: cint; buf: pointer; n: int): int {.importc: "nn_sock_read".}
  proc sockWrite*(fd: cint; buf: pointer; n: int): int {.importc: "nn_sock_write".}
  proc sockReadv*(fd: cint; iov: pointer; n: cint): int {.importc: "nn_sock_readv".}
  proc sockWritev*(fd: cint; iov: pointer; n: cint): int {.importc: "nn_sock_writev".}
  proc sockPoll*(fds: ptr PollFd; n, timeoutMs: cint): cint {.importc: "nn_sock_poll".}
  proc nnSockNonblock(fd, on: cint): cint {.importc: "nn_sock_nonblock".}
  proc nnSockPair(sv: ptr cint): cint {.importc: "nn_sock_pair".}
  proc nnWakePair(r, w: ptr cint): cint {.importc: "nn_wake_pair".}
  proc nnWakeSignal(w: cint) {.importc: "nn_wake_signal".}
  proc nnWakeDrain(r: cint) {.importc: "nn_wake_drain".}
  proc nnSleepUs(us: cuint) {.importc: "nn_sleep_us".}
  proc nnGetpid(): cint {.importc: "nn_getpid".}
  proc nnRealtimeNs(): int64 {.importc: "nn_realtime_ns".}
  proc nnOnConsoleCtrl(cb: proc (sig: cint): cint {.noconv.}): cint {.importc: "nn_on_console_ctrl".}
  proc nnConsoleCtrlRaise(sig: cint): cint {.importc: "nn_console_ctrl_raise".}

  proc sockSetNonblock*(fd: cint; on: bool): bool = nnSockNonblock(fd, cint(ord(on))) == 0
  proc sockNonblock*(fd: cint): bool = nnSockNonblock(fd, 1) == 0

  proc sockShutdown*(fd, how: cint): cint = nnSockShutdown(fd, how)
  proc onConsoleCtrl*(cb: proc (sig: cint): cint {.noconv.}): bool {.inline.} =
    ## `cb` runs, on a thread the system starts, for Ctrl+C and Ctrl+Break
    ## (2, as SIGINT) and for closing the console, logoff and shutdown (15,
    ## as SIGTERM). The newest callback runs first; returning nonzero takes
    ## the event, otherwise the process ends as it would have.
    result = nnOnConsoleCtrl(cb) == 0
  proc raiseConsoleCtrl*(sig: cint): bool =
    ## Run the console handlers as the system would for `sig` (2 or 15);
    ## true when one took it. For tests: a real Ctrl+Break reaches every
    ## process attached to the console.
    result = nnConsoleCtrlRaise(sig) != 0
  proc sockPair*(sv: ptr cint): cint = nnSockPair(sv)
    ## A connected stream pair (loopback TCP on Windows).
  proc wakePair*(r, w: var cint): bool = nnWakePair(addr r, addr w) == 0
  proc wakeSignal*(w: cint) = nnWakeSignal(w)
  proc wakeDrain*(r: cint) = nnWakeDrain(r)
  proc wakeClose*(r, w: cint) = discard sockClose(r)
  proc sleepUs*(us: int) = nnSleepUs(cuint(us))
  proc getPid*(): int = int(nnGetpid())
  proc realtimeNs*(): int64 = nnRealtimeNs()
  proc fileWrite*(fd: cint; buf: pointer; n: int): int {.importc: "_write", header: "<io.h>".}
    ## A C-runtime descriptor (stderr, a log file), not a socket.

  proc sockAbort*(fd: cint): bool =
    ## Not on Windows: closesocket alone resets (see the other branch).
    discard fd
    result = false

else:
  proc sockSocket*(af, kind, proto: cint): cint {.importc: "socket", header: "<sys/socket.h>".}
  proc sockClose*(fd: cint): cint {.importc: "close", header: "<unistd.h>".}
  proc sockBind*(fd: cint; sa: pointer; len: cuint): cint {.importc: "bind", header: "<sys/socket.h>".}
  proc sockConnect*(fd: cint; sa: pointer; len: cuint): cint {.importc: "connect", header: "<sys/socket.h>".}
  proc sockListen*(fd, backlog: cint): cint {.importc: "listen", header: "<sys/socket.h>".}
  proc sockAccept*(fd: cint; sa: nil pointer; len: nil ptr cuint): cint {.importc: "accept", header: "<sys/socket.h>".}
  proc sockShutdown*(fd, how: cint): cint {.importc: "shutdown", header: "<sys/socket.h>".}
  when defined(macosx):
    proc cDisconnectx(fd: cint; aid: uint32; cid: uint32): cint {.importc: "disconnectx", header: "<sys/socket.h>".}
  proc sockAbort*(fd: cint): bool =
    ## Disconnect a connected TCP socket now, waking whatever waits on it:
    ## with SO_LINGER 0 set, a reset (Linux: connect to AF_UNSPEC; macOS:
    ## disconnectx). False where the system has no such call, or refuses
    ## (a kTLS socket on Linux).
    when defined(linux):
      var sa = default(array[16, byte])          # sa_family 0: AF_UNSPEC
      result = sockConnect(fd, addr sa[0], cuint(sa.len)) == 0
    elif defined(macosx):
      result = cDisconnectx(fd, 0'u32, 0'u32) == 0   # SAE_ASSOCID_ANY, SAE_CONNID_ANY
    else:
      discard fd
      result = false
  proc sockSetsockopt*(fd, level, opt: cint; v: pointer; len: cuint): cint {.importc: "setsockopt", header: "<sys/socket.h>".}
  proc sockGetsockopt*(fd, level, opt: cint; v: pointer; len: ptr cuint): cint {.importc: "getsockopt", header: "<sys/socket.h>".}
  proc sockGetsockname*(fd: cint; sa: pointer; len: ptr cuint): cint {.importc: "getsockname", header: "<sys/socket.h>".}
  proc sockGetpeername*(fd: cint; sa: pointer; len: ptr cuint): cint {.importc: "getpeername", header: "<sys/socket.h>".}
  proc sockRecv*(fd: cint; buf: pointer; n: csize_t; flags: cint): int {.importc: "recv", header: "<sys/socket.h>".}
  proc sockSend*(fd: cint; buf: pointer; n: csize_t; flags: cint): int {.importc: "send", header: "<sys/socket.h>".}
  proc sockRecvfrom*(fd: cint; buf: pointer; n: csize_t; flags: cint; sa: nil pointer; len: nil ptr cuint): int {.importc: "recvfrom", header: "<sys/socket.h>".}
  proc sockSendto*(fd: cint; buf: pointer; n: csize_t; flags: cint; sa: pointer; len: cuint): int {.importc: "sendto", header: "<sys/socket.h>".}
  proc sockRead*(fd: cint; buf: pointer; n: int): int {.importc: "read", header: "<unistd.h>".}
  proc sockWrite*(fd: cint; buf: pointer; n: int): int {.importc: "write", header: "<unistd.h>".}
  proc sockReadv*(fd: cint; iov: pointer; n: cint): int {.importc: "readv", header: "<sys/uio.h>".}
  proc sockWritev*(fd: cint; iov: pointer; n: cint): int {.importc: "writev", header: "<sys/uio.h>".}
  proc sockPoll*(fds: ptr PollFd; n, timeoutMs: cint): cint {.importc: "poll", header: "<poll.h>".}
  proc cSocketpair(d, t, p: cint; sv: ptr cint): cint {.importc: "socketpair", header: "<sys/socket.h>".}
  proc cPipe(fds: ptr cint): cint {.importc: "pipe", header: "<unistd.h>".}
  proc cFcntl(fd, cmd: cint): cint {.importc: "fcntl", header: "<fcntl.h>", varargs.}
  proc cUsleep(us: cuint): cint {.importc: "usleep", header: "<unistd.h>".}
  proc cGetpid(): cint {.importc: "getpid", header: "<unistd.h>".}

  type Timespec {.importc: "struct timespec", header: "<time.h>".} = object
    tv_sec: int
    tv_nsec: int
  proc clockGettime(clk: cint; ts: ptr Timespec): cint {.importc: "clock_gettime", header: "<time.h>".}

  const
    FGetFl = 3.cint
    FSetFl = 4.cint
    FSetFd = 2.cint
    ONonblock = when defined(macosx): 4.cint else: 2048.cint

  proc sockSetNonblock*(fd: cint; on: bool): bool =
    # fcntl is variadic: Darwin ARM64 passes the third argument on the
    # stack, so the binding must be declared varargs.
    let flags = cFcntl(fd, FGetFl)
    if flags < 0: return false
    if ((flags and ONonblock) != 0) == on: return true
    let want = if on: flags or ONonblock else: flags and not ONonblock
    result = cFcntl(fd, FSetFl, want) == 0

  proc sockNonblock*(fd: cint): bool = sockSetNonblock(fd, true)

  proc setCloexec(fd: cint) = discard cFcntl(fd, FSetFd, 1.cint)

  proc sockPair*(sv: ptr cint): cint = cSocketpair(1.cint, 1.cint, 0.cint, sv)
    ## A connected stream pair (AF_UNIX).

  proc wakePair*(r, w: var cint): bool =
    ## A non-blocking pipe.
    var fds = default(array[2, cint])
    if cPipe(addr fds[0]) != 0: return false
    var k = 0
    while k < 2:
      discard sockNonblock(fds[k])
      setCloexec(fds[k])
      k = k + 1
    r = fds[0]
    w = fds[1]
    result = true

  proc wakeSignal*(w: cint) =
    var b = 1'u8
    discard sockWrite(w, addr b, 1)

  proc wakeDrain*(r: cint) =
    var buf = default(array[64, byte])
    while sockRead(r, addr buf[0], buf.len) > 0: discard

  proc wakeClose*(r, w: cint) =
    discard sockClose(r)
    if w != r: discard sockClose(w)

  proc sleepUs*(us: int) = discard cUsleep(cuint(us))
  proc fileWrite*(fd: cint; buf: pointer; n: int): int {.importc: "write", header: "<unistd.h>".}
    ## A descriptor that is not a socket (stderr, a log file).
  proc getPid*(): int = int(cGetpid())

  proc realtimeNs*(): int64 =
    var ts = default(Timespec)
    discard clockGettime(0.cint, addr ts)          # CLOCK_REALTIME
    result = int64(ts.tv_sec) * 1_000_000_000 + int64(ts.tv_nsec)
