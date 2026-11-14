# Included by linux.nim and macos.nim after they define ONonblock, NoFile,
# MapPrivateAnon and fdCeiling. Each call is the C library's own.

proc sockSocket*(af, kind, proto: cint): cint {.importc: "socket", header: "<sys/socket.h>".}
proc sockClose*(fd: cint): cint {.importc: "close", header: "<unistd.h>".}
proc sockBind*(fd: cint; sa: pointer; len: cuint): cint {.importc: "bind", header: "<sys/socket.h>".}
proc sockConnect*(fd: cint; sa: pointer; len: cuint): cint {.importc: "connect", header: "<sys/socket.h>".}
proc sockListen*(fd, backlog: cint): cint {.importc: "listen", header: "<sys/socket.h>".}
proc sockAccept*(fd: cint; sa: nil pointer; len: nil ptr cuint): cint {.importc: "accept", header: "<sys/socket.h>".}
proc sockShutdown*(fd, how: cint): cint {.importc: "shutdown", header: "<sys/socket.h>".}
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

proc makeNonblocking*(fd: cint): bool {.noinline.} = sockNonblock(fd)

proc cSignal(sig: cint; handler: nil pointer): nil pointer {.importc: "signal", header: "<signal.h>".}

proc ignoreSigpipe*() =
  ## Make a write to a closed or shut-down socket fail with EPIPE instead
  ## of killing the process: `writev` and `splice` take no MSG_NOSIGNAL.
  ## Process-wide; `initRuntime` calls it.
  const SigPipe = 13.cint   # Linux, macOS and the BSDs
  discard cSignal(SigPipe, cast[pointer](1))   # SIG_IGN

type RLimit {.importc: "struct rlimit", header: "<sys/resource.h>".} = object
  rlim_cur: uint64
  rlim_max: uint64

proc getrlimit(resource: cint; rlp: ptr RLimit): cint {.importc, header: "<sys/resource.h>".}
proc setrlimit(resource: cint; rlp: ptr RLimit): cint {.importc, header: "<sys/resource.h>".}
proc raiseFdLimit*(want = 1 shl 20): int =
  ## Raise the descriptor limit toward `want` and return the new soft
  ## limit. The soft limit rises to the hard limit; a privileged process
  ## (root, or CAP_SYS_RESOURCE on Linux) raises the hard limit too, as far
  ## as the kernel allows (fs.nr_open on Linux, kern.maxfilesperproc on
  ## macOS). launchd starts macOS processes with a soft limit of 256.
  var r = default(RLimit)
  if getrlimit(NoFile, addr r) != 0: return -1
  var target = min(uint64(want), fdCeiling())
  # Above the hard limit: only a privileged process may; halve until the
  # kernel agrees (EPERM otherwise).
  var t = target
  while t > r.rlim_max and t > r.rlim_cur:
    var n = r
    n.rlim_cur = t
    n.rlim_max = t
    if setrlimit(NoFile, addr n) == 0: return int(t)
    t = t div 2
  # Up to the hard limit.
  if target > r.rlim_max: target = r.rlim_max
  while target > r.rlim_cur:
    var n = r
    n.rlim_cur = target
    if setrlimit(NoFile, addr n) == 0: return int(target)
    target = target div 2
  result = int(r.rlim_cur)

proc fdLimits*(soft, hard: var int): bool =
  ## The current descriptor limits (hard may be very large: unlimited).
  var r = default(RLimit)
  result = getrlimit(NoFile, addr r) == 0
  soft = int(min(r.rlim_cur, uint64(high(int))))
  hard = int(min(r.rlim_max, uint64(high(int))))

proc cMmap(a: nil pointer; len: csize_t; prot, flags, fd: cint; off: int): nil pointer {.importc: "mmap", header: "<sys/mman.h>".}
proc cMunmap(a: pointer; len: csize_t): cint {.importc: "munmap", header: "<sys/mman.h>".}

const
  ProtReadWrite = 3.cint

proc mapAnon*(len: int): nil pointer =
  ## Zeroed private memory whose pages become resident only when touched;
  ## nil on failure. For large buffers that are mostly left unused.
  result = cMmap(nil, csize_t(len), ProtReadWrite, MapPrivateAnon, -1.cint, 0)
  if cast[int](result) == -1: result = nil

proc unmapAnon*(p: nil pointer; len: int) =
  if p != nil: discard cMunmap(p, csize_t(len))
