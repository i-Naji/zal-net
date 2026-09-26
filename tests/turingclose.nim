## std/ioring (the std backend's ring): closing a descriptor while a poll on
## it is in flight releases the socket, so the peer reads end of stream at
## once. On io_uring a pending poll holds its own reference to the socket
## until it is cancelled, and `closeFd` cancels it by descriptor
## (IORING_ASYNC_CANCEL_FD, Linux 5.19). A kernel with io_uring but without
## that cancel (5.1 to 5.18) must get the epoll backend instead
## (ci/nimony-uringprobe.patch).
when defined(windows):
  import std/syncio
  echo "SKIP no socketpair on Windows (IOCP aborts on closesocket)"
else:
  import std/[ioring, syncio]

  type PollFd {.importc: "struct pollfd", header: "<poll.h>".} = object
    fd: cint
    events, revents: cshort

  proc socketpair(domain, typ, protocol: cint; sv: ptr cint): cint {.importc, header: "<sys/socket.h>".}
  proc cPoll(fds: ptr PollFd; n: cuint; timeoutMs: cint): cint {.importc: "poll", header: "<poll.h>".}
  proc cRecv(fd: cint; buf: pointer; len: int; flags: cint): int {.importc: "recv", header: "<sys/socket.h>".}

  const
    AfUnix = 1.cint
    SockStream = 1.cint
    PollIn = 1.cshort

  var fds = default(array[2, cint])
  if socketpair(AfUnix, SockStream, 0, addr fds[0]) != 0: quit "FAIL socketpair"
  setNonBlocking(fds[0])
  setNonBlocking(fds[1])
  var comps = default(array[8, IoCompletion])

  # A poll that nothing will satisfy, handed to the kernel (the ring submits
  # on this thread's poll), then the descriptor closed under it.
  discard submitPollAdd(fds[0], never, {evRead})
  discard pollCompletions(comps)
  closeFd(fds[0])

  var p = PollFd(fd: fds[1], events: PollIn, revents: 0)
  let ready = cPoll(addr p, 1, 2000)
  var buf = default(array[8, char])
  let n = if ready == 1: cRecv(fds[1], addr buf[0], buf.len, 0) else: -1
  while pollCompletions(comps) > 0: discard
  closeFdRaw(fds[1])
  if n != 0:
    quit "FAIL the peer saw no end of stream within 2 s: the ring still holds the closed socket"
  echo "PASS closing a descriptor with a poll in flight releases the socket"
