## Typed datagram I/O shared by raw and optional managed owners.
## Callers borrow descriptors and buffers; this frame retains both cancellation
## sources through poll completion. No per-operation cancellation allocation.
import std/oserrors
import zal_net/[rt, errors], zal_net/raw/io
import zal_net/net/[address, sockaddr], zal_net/raw/mmsg
import zal_net/private/sys/[sock, posix]
import zal_net/private/sys/[dgram, types]
import zal_net/net/datagraminfo
import zal_net/private/core/iocancel

# Scalar address-based operations stay in the caller's passive frame. Every
# argument is captured once, and both cancellation sources remain retained
# through the final readiness completion.
template udpSendTo*(fd, family: cint; timeoutMs: int; p: pointer; n: int; to: SocketAddress;
                    deadline: Deadline; tokens: IoCancellation): int =
  block:
    let descriptor = fd
    let socketFamily = family
    let idleLimit = timeoutMs
    let buffer = p
    let count = n
    let destination = to
    let operationDeadline = deadline
    let operationTokens = tokens
    retain(operationTokens)
    var outcome = InvalidInput
    if count >= 0:
      let sa = forFamily(destination, socketFamily)
      let d = limit(idleLimit, operationDeadline)
      var ready = 0
      ioCheckpoint(min(count, 65536))
      while true:
        if cancelled(operationTokens):
          outcome = ECancelled
          break
        if d <= monoNow():
          outcome = IoTimedOut
          break
        let k = sockSendto(descriptor, buffer, csize_t(count), 0, unsafeAddr sa.ss, sa.len)
        if k >= 0:
          outcome = k
          break
        let err = int(osLastError())
        if err == EIntr: continue
        if err != EAgain:
          outcome = -err
          break
        parkCancellable(descriptor, {evWrite}, d, operationTokens, ready)
        if ready <= 0:
          outcome = if ready < 0: ready else: ResourceClosed
          break
    release(operationTokens)
    outcome

template udpRecvFrom*(fd: cint; timeoutMs: int; p: pointer; n: int; src: nil ptr SocketAddress;
                      deadline: Deadline; tokens: IoCancellation): int =
  block:
    let descriptor = fd
    let idleLimit = timeoutMs
    let buffer = p
    let count = n
    let source = src
    let operationDeadline = deadline
    let operationTokens = tokens
    retain(operationTokens)
    var outcome = InvalidInput
    if count >= 0:
      # Darwin can complete recvfrom(..., 0) without consuming a datagram or
      # filling its source. Consume one discarded byte for an empty window.
      var discarded = 0'u8
      let target = if count == 0: cast[pointer](addr discarded) else: buffer
      let capacity = max(1, count)
      let d = limit(idleLimit, operationDeadline)
      var ready = 0
      ioCheckpoint(min(count, 65536))
      while true:
        if cancelled(operationTokens):
          outcome = ECancelled
          break
        if d <= monoNow():
          outcome = IoTimedOut
          break
        var sa = default(SockAddrBuf)
        sa.len = cuint(sizeof(SockaddrStorage))
        let k = sockRecvfrom(descriptor, target, csize_t(capacity), 0, addr sa.ss, addr sa.len)
        if k >= 0:
          if source != nil: source.raw = sa
          outcome = min(k, count)
          break
        let err = int(osLastError())
        if err == EIntr: continue
        if err != EAgain:
          outcome = -err
          break
        parkCancellable(descriptor, {evRead}, d, operationTokens, ready)
        if ready <= 0:
          outcome = if ready < 0: ready else: ResourceClosed
          break
    release(operationTokens)
    outcome

proc udpSend*(fd: cint; timeoutMs: int; p: pointer; n: int; deadline = never;
           tokens: IoCancellation): int {.passive.} =
  if n < 0: return InvalidInput
  retain(tokens)
  defer: release(tokens)
  ## On a connected socket.
  let d = limit(timeoutMs, deadline)
  var res = 0
  ioCheckpoint(min(n, 65536))
  while true:
    if cancelled(tokens): return ECancelled
    if d <= monoNow(): return IoTimedOut
    let k = sockSend(fd, p, csize_t(n), 0)
    if k >= 0: return k
    let err = int(osLastError())
    if err == EIntr: continue
    if err != EAgain: return -err
    parkCancellable(fd, {evWrite}, d, tokens, res)
    if res <= 0: return (if res < 0: res else: ResourceClosed)


proc udpRecv*(fd: cint; timeoutMs: int; p: pointer; n: int; deadline = never;
           tokens: IoCancellation): int {.passive.} =
  if n < 0: return InvalidInput
  retain(tokens)
  defer: release(tokens)
  ## On a connected socket.
  var discarded = 0'u8
  let target = if n == 0: cast[pointer](addr discarded) else: p
  let capacity = max(1, n)
  let d = limit(timeoutMs, deadline)
  var res = 0
  ioCheckpoint(min(n, 65536))
  while true:
    if cancelled(tokens): return ECancelled
    if d <= monoNow(): return IoTimedOut
    let k = sockRecv(fd, target, csize_t(capacity), 0)
    if k >= 0: return min(k, n)
    let err = int(osLastError())
    if err == EIntr: continue
    if err != EAgain: return -err
    parkCancellable(fd, {evRead}, d, tokens, res)
    if res <= 0: return (if res < 0: res else: ResourceClosed)


proc udpRecvBatch*(fd: cint; timeoutMs: int; b: ptr MmsgBatch; deadline = never;
                tokens: IoCancellation): int {.passive.} =
  ## Up to b.cap datagrams in one system call, after waiting for the
  ## first: how many, or <0. Read them with `datagramLen`, `peerLen`,
  ## `groSegment` and `b.slots[i]`.
  if b.cap <= 0 or b.cap > MaxBatchSlots or b.hdrs.len < b.cap or b.slots == nil: return InvalidInput
  retain(tokens)
  defer: release(tokens)
  let d = limit(timeoutMs, deadline)
  var res = 0
  while true:
    ioCheckpoint(0)
    if cancelled(tokens): return ECancelled
    if d <= monoNow(): return IoTimedOut
    let k = recvmmsgBatch(fd, b[], MSG_DONTWAIT)
    if k > 0: return k
    let err = int(osLastError())
    if k < 0 and err == EIntr: continue
    if k < 0 and err != EAgain: return -err
    parkCancellable(fd, {evRead}, d, tokens, res)
    if res <= 0: return (if res < 0: res else: ResourceClosed)

proc udpSendBatch*(fd: cint; timeoutMs: int; b: ptr MmsgBatch; n: int; deadline = never;
                tokens: IoCancellation): int {.passive.} =
  ## The first `n` datagrams set with `setOutgoing`, in as few system calls
  ## as the kernel takes: how many went out.
  result = 0
  if n < 0 or n > b.cap or b.cap > MaxBatchSlots or b.hdrs.len < b.cap or b.slots == nil: return InvalidInput
  if n == 0: return
  retain(tokens)
  defer: release(tokens)
  let d = limit(timeoutMs, deadline)
  var res = 0
  while result < n:
    ioCheckpoint(0)
    if cancelled(tokens): return (if result > 0: result else: ECancelled)
    if d <= monoNow(): return (if result > 0: result else: IoTimedOut)
    let k = sendmmsgRaw(fd, addr b.hdrs[result], cuint(n - result), 0)
    if k > 0:
      result = result + k
    else:
      if k == 0: return (if result > 0: result else: NoProgress)
      let err = int(osLastError())
      if err == EIntr: continue
      if err != EAgain: return (if result > 0: result else: -err)
      parkCancellable(fd, {evWrite}, d, tokens, res)
      if res <= 0: return (if result > 0: result else: (if res < 0: res else: NoProgress))


proc udpRecvInfo*(fd: cint; timeoutMs: int; p: pointer; n: int; info: ptr DatagramInfo; deadline: Deadline; tokens: IoCancellation): int {.passive.} =
  if n < 0: return InvalidInput
  retain(tokens)
  defer: release(tokens)
  ## One datagram and what the kernel knows about it: its length, or <0.
  var discarded = 0'u8
  let target = if n == 0: cast[pointer](addr discarded) else: p
  let capacity = max(1, n)
  let d = limit(timeoutMs, deadline)
  var res = 0
  ioCheckpoint(min(n, 65536))
  while true:
    if cancelled(tokens): return ECancelled
    if d <= monoNow(): return IoTimedOut
    var sa = default(SockAddrBuf)
    sa.len = cuint(sizeof(SockaddrStorage))
    var di {.noinit.}: NnDinfo
    let k = nnRecvInfo(fd, target, csize_t(capacity), addr sa.ss, addr sa.len, addr di)
    if k >= 0:
      if info != nil:
        info.source = fromRaw(sa)
        info.hasDestination = di.dstFamily != 0
        info.destination = default(IpAddress)
        if di.dstFamily == AF_INET:
          info.destination = ipv4(di.dst[0], di.dst[1], di.dst[2], di.dst[3])
        elif di.dstFamily == AF_INET6:
          info.destination = unmapped(IpAddress(family: ipv6, bytes: di.dst))
        info.interfaceIndex = uint32(di.ifindex)
        info.ttl = int(di.ttl)
        info.tos = int(di.tos)
        info.truncated = di.truncated != 0 or k > n
      return min(int(k), n)
    let err = int(osLastError())
    if err == EIntr: continue
    if err != EAgain: return -err
    parkCancellable(fd, {evRead}, d, tokens, res)
    if res <= 0: return (if res < 0: res else: ResourceClosed)

proc udpSendWithSource*(fd, family: cint; timeoutMs: int; p: pointer; n: int; to: SocketAddress; source: IpAddress;
               ifIndex: uint32; deadline: Deadline; tokens: IoCancellation): int {.passive.} =
  if n < 0: return InvalidInput
  retain(tokens)
  defer: release(tokens)
  ## One datagram sent from `source` (for instance the destination a
  ## request came to, on a host with several addresses) and interface.
  let sa = forFamily(to, family)
  var src = source
  var fam = if source.family == ipv4: AF_INET else: AF_INET6
  if family == AF_INET6 and source.family == ipv4:
    src = IpAddress(family: ipv6)
    src.bytes[10] = 0xff
    src.bytes[11] = 0xff
    copyMem(addr src.bytes[12], unsafeAddr source.bytes[0], 4)
    fam = AF_INET6
  let d = limit(timeoutMs, deadline)
  var res = 0
  ioCheckpoint(min(n, 65536))
  while true:
    if cancelled(tokens): return ECancelled
    if d <= monoNow(): return IoTimedOut
    let k = nnSendFrom(fd, p, csize_t(n), unsafeAddr sa.ss, sa.len, addr src.bytes[0], fam, cuint(ifIndex))
    if k >= 0: return int(k)
    let err = int(osLastError())
    if err == EIntr: continue
    if err != EAgain: return -err
    parkCancellable(fd, {evWrite}, d, tokens, res)
    if res <= 0: return (if res < 0: res else: ResourceClosed)

