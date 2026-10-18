import zal_net/buffers
import zal_net/errors
export dataPtr
## The operations every byte stream shares (TCP, Unix-domain), over a
## descriptor and an idle limit. `net/tcp` and `net/unix` wrap them per
## type; use those.

import std/oserrors
import zal_net/rt
import zal_net/rt/cancel
import zal_net/private/core/iocancel
import zal_net/private/core/udpops
import zal_net/raw/io
import zal_net/private/sys/posix
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/net/address
import zal_net/private/sys/sock


const
  IoChunk* = 64 * 1024  ## the most one inline call moves unless told otherwise

template fdRecvInline*(fd: cint; timeoutMs: int; p: pointer; n: int;
                       deadline: Deadline; outcome: var int; tok: nil CancelToken = nil; ownerCancel: nil CancelToken = nil; peerCancel: nil CancelToken = nil;
                       chunk = IoChunk) =
  ## Suspend in the caller's passive frame; built-in pumps use this to avoid
  ## allocating a child frame for each ready read. Owners/buffers stay borrowed.
  ## One call moves at most `chunk` bytes, so other tasks get their turn.
  block:
    let operationToken: nil CancelToken = tok
    let ownerToken: nil CancelToken = ownerCancel
    let peerToken: nil CancelToken = peerCancel
    retain(ownerToken)
    retain(peerToken)
    let cancellationSources = ioCancellation(operationToken, ownerToken, peerToken, interrupts = true)
    if operationToken != nil: retain(operationToken)
    let count = n
    outcome = InvalidInput
    if count == 0:
      outcome = 0
    elif count > 0:
      let d = limit(timeoutMs, deadline)
      var ready = 0
      ioCheckpoint(min(count, chunk))
      while true:
        if cancelled(cancellationSources) or stopping():
          outcome = ECancelled
          break
        if d <= monoNow():
          outcome = IoTimedOut
          break
        outcome = readSome(fd, p, min(count, chunk))
        if outcome != IoAgain: break
        parkCancellable(fd, {evRead}, d, cancellationSources, ready)
        if ready <= 0:
          outcome = if ready < 0: ready else: -1
          break
    if operationToken != nil: release(operationToken)
    release(ownerToken)
    release(peerToken)

proc fdRecv*(fd: cint; timeoutMs: int; p: pointer; n: int; deadline: Deadline; tok: nil CancelToken = nil): int {.passive.} =
  fdRecvInline(fd, timeoutMs, p, n, deadline, result, tok)

template fdSendInline*(fd: cint; timeoutMs: int; p: pointer; n: int;
                       deadline: Deadline; outcome: var int; tok: nil CancelToken = nil; ownerCancel: nil CancelToken = nil; peerCancel: nil CancelToken = nil;
                       chunk = IoChunk) =
  block:
    let operationToken: nil CancelToken = tok
    let ownerToken: nil CancelToken = ownerCancel
    let peerToken: nil CancelToken = peerCancel
    retain(ownerToken)
    retain(peerToken)
    let cancellationSources = ioCancellation(operationToken, ownerToken, peerToken, interrupts = true)
    if operationToken != nil: retain(operationToken)
    let count = n
    outcome = InvalidInput
    if count == 0:
      outcome = 0
    elif count > 0:
      let d = limit(timeoutMs, deadline)
      var ready = 0
      ioCheckpoint(min(count, chunk))
      while true:
        if cancelled(cancellationSources) or stopping():
          outcome = ECancelled
          break
        if d <= monoNow():
          outcome = IoTimedOut
          break
        outcome = writeSome(fd, p, min(count, chunk))
        if outcome != IoAgain: break
        parkCancellable(fd, {evWrite}, d, cancellationSources, ready)
        if ready <= 0:
          outcome = if ready < 0: ready else: -1
          break
    if operationToken != nil: release(operationToken)
    release(ownerToken)
    release(peerToken)

proc fdSend*(fd: cint; timeoutMs: int; p: pointer; n: int; deadline: Deadline; tok: nil CancelToken = nil): int {.passive.} =
  fdSendInline(fd, timeoutMs, p, n, deadline, result, tok)

proc fdRecvv*(fd: cint; timeoutMs: int; iov: ptr IoVec; count: int; deadline: Deadline; tok: nil CancelToken = nil): int {.passive.} =
  retain(tok)
  defer: release(tok)
  if count < 0: return InvalidInput
  if count == 0: return 0
  let d = limit(timeoutMs, deadline)
  var res = 0
  ioCheckpoint(0)
  while true:
    if cancelled(tok) or stopping(): return ECancelled
    if d <= monoNow(): return IoTimedOut
    let k = sockReadv(fd, iov, cint(count))
    if k >= 0: return k
    let err = int(osLastError())
    if err == EIntr: continue
    if err != EAgain: return -err
    parkCancellable(fd, {evRead}, d, tok, res)
    if res <= 0: return (if res < 0: res else: -1)

proc fdSendv*(fd: cint; timeoutMs: int; iov: ptr IoVec; count: int; deadline: Deadline; tok: nil CancelToken = nil): int {.passive.} =
  retain(tok)
  defer: release(tok)
  if count < 0: return InvalidInput
  if count == 0: return 0
  let d = limit(timeoutMs, deadline)
  var res = 0
  ioCheckpoint(0)
  while true:
    if cancelled(tok) or stopping(): return ECancelled
    if d <= monoNow(): return IoTimedOut
    let k = sockWritev(fd, iov, cint(count))
    if k >= 0: return k
    let err = int(osLastError())
    if k < 0 and err == EIntr: continue
    if k < 0 and err != EAgain: return -err
    parkCancellable(fd, {evWrite}, d, tok, res)
    if res <= 0: return (if res < 0: res else: -1)

proc fdReadExactly*(fd: cint; timeoutMs: int; p: pointer; n: int; deadline: Deadline; tok: nil CancelToken = nil): bool {.passive.} =
  retain(tok)
  defer: release(tok)
  result = n >= 0
  var off = 0
  while off < n:
    let k = fdRecv(fd, timeoutMs, offset(bytesPtr(p), off), n - off, deadline, tok)
    if k <= 0: return false
    off = off + k

proc fdWriteAll*(fd: cint; timeoutMs: int; p: pointer; n: int; deadline: Deadline; tok: nil CancelToken = nil): bool {.passive.} =
  retain(tok)
  defer: release(tok)
  result = n >= 0
  var off = 0
  while off < n:
    let k = fdSend(fd, timeoutMs, offset(bytesPtr(p), off), n - off, deadline, tok)
    if k <= 0: return false
    off = off + k

const
  DefaultTimeoutMs* = 60_000     ## idle limit per operation of a new stream or socket

type
  Shutdown* = enum
    shutRead, shutWrite, shutBoth

proc fdShutdown*(fd: cint; how: int) =
  if fd >= 0: discard sockShutdown(fd, cint(how))

proc fdLocal*(fd: cint): SocketAddress =
  result = default(SocketAddress)
  result.raw.len = cuint(sizeof(SockaddrStorage))
  if fd < 0 or sockGetsockname(fd, addr result.raw.ss, addr result.raw.len) != 0: result.raw.len = 0

proc fdRemote*(fd: cint): SocketAddress =
  result = default(SocketAddress)
  result.raw.len = cuint(sizeof(SockaddrStorage))
  if fd < 0 or sockGetpeername(fd, addr result.raw.ss, addr result.raw.len) != 0: result.raw.len = 0

# ---------------------------------------------------------------- datagrams


template fdSendTo*(fd, family: cint; timeoutMs: int; p: pointer; n: int;
                   to: SocketAddress; deadline: Deadline;
                   tok: nil CancelToken = nil): int =
  udpSendTo(fd, family, timeoutMs, p, n, to, deadline, ioCancellation(tok))

template fdRecvFrom*(fd: cint; timeoutMs: int; p: pointer; n: int;
                     src: nil ptr SocketAddress; deadline: Deadline;
                     tok: nil CancelToken = nil): int =
  udpRecvFrom(fd, timeoutMs, p, n, src, deadline, ioCancellation(tok))
