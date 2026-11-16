## Windows: every call goes through sys/win/nn_win.c, which calls Winsock with
## the descriptor as a SOCKET and reports failures as POSIX errno values
## (Linux numbering) through osLastError, so callers compare against EAgain,
## EIntr and the rest the same way as on the other systems.

import zal_net/private/os/common
export common
import zal_net/net/sockaddr   # compiles and links sys/win/*.c

const
  EAgain* = 11
  ENoBufs* = 105
  EConnRefused* = 111
  ENotSocket* = 88

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

proc makeNonblocking*(fd: cint): bool {.noinline.} = sockNonblock(fd)

proc raiseFdLimit*(want = 1 shl 20): int = want
  ## Windows has no descriptor limit to raise.

proc fdLimits*(soft, hard: var int): bool =
  soft = 1 shl 24
  hard = 1 shl 24
  result = true

proc nnMapAnon(len: csize_t): nil pointer {.importc: "nn_map_anon".}
proc nnUnmapAnon(p: nil pointer; len: csize_t) {.importc: "nn_unmap_anon".}

proc mapAnon*(len: int): nil pointer = nnMapAnon(csize_t(len))
  ## Zeroed memory, committed as touched; nil on failure.

proc unmapAnon*(p: nil pointer; len: int) = nnUnmapAnon(p, csize_t(len))

proc ignoreSigpipe*() = discard
  ## Windows has no SIGPIPE: a send to a closed peer fails with an error.

proc cpuQuota*(): int = 0
  ## No CPU quota to honour here (see the Linux version).
