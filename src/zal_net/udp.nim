# A UDP socket: one datagram descriptor, its deadline and its stop token. The
# shape follows `std/socket` and `zal_net/conn`, so a datagram client reads
# like a stream client.
#
#   var u = openUdp(0, "127.0.0.1")
#   u.connect("127.0.0.1", 5353, afterMs(1_000))
#   u.send query
#   var answer = default(array[1500, byte])
#   let n = u.recv(answer, afterMs(1_000))
#
# A server leaves its socket unconnected. `recvFrom` says who sent a datagram
# and `sendTo` answers there:
#
#   var peer = default(SocketAddress)
#   let n = u.recvFrom(buf, peer)
#   u.sendTo(buf.toOpenArray(0, n - 1), peer)
#
# Datagrams are whole messages. A send emits one datagram, an empty one
# included, and raises unless all of it went out. A receive takes one
# datagram and answers its length; the tail of a datagram longer than the
# buffer is lost. 0 means an empty datagram arrived: a datagram socket has no
# end of stream. A receive into an empty buffer still consumes a datagram.
#
# A `UdpSocket` owns its descriptor the way a `Conn` does. It cannot be
# copied, moving it moves the descriptor, and it closes when it goes out of
# scope. One task uses it at a time, which is why no operation takes a lock.
# Multicast, broadcast, per-datagram metadata and batches stay in
# `zal_net/raw/udp`; `nativeHandle` reaches them.
#
# A failure is never in the return value. Everything raises an `ErrorCode`:
# `TimeoutError` when the deadline came first, `AbortedOperation` when the
# token was cancelled. Cancelling leaves the descriptor alone, so a parked
# wait sees it at its next poll, and those come 10 to 200 ms apart
# (`CancelPollMs` and `CancelPollMaxMs` in `private/core/iocancel`).
#
# `recvFrom`, `sendTo`, `recv` and `send` are templates that wait in the
# caller's frame, for the reasons the header of `zal_net/conn` gives.
#
# A socket bound to every address (host "") is IPv6 with IPv4 mapped in,
# where the system has IPv6. An IPv4 peer then arrives as `::ffff:a.b.c.d`;
# `ip` of that address answers the plain IPv4 one, and `sendTo` takes
# either form.

import std/oserrors
import zal_net/rt
import zal_net/rt/[cancel, time]
import zal_net/raw/fdops
import zal_net/raw/udp as rawudp
import zal_net/net/[address, failure, sockaddr, dns]
import zal_net/private/os
import zal_net/private/core/[iocancel, udpops]
import zal_net/errors

export time, cancel.CancelToken, cancel.newCancelToken, cancel.cancel, cancel.cancelled
export address.SocketAddress

const
  NoIdleLimitMs = 0
    ## The raw calls take an idle limit in milliseconds next to the deadline,
    ## and 0 turns it off. Here the deadline alone decides.

type
  UdpSocket* = object
    ## A datagram socket that owns its descriptor. It is move-only, so one
    ## value closes the descriptor, once.
    fd: cint
    family: cint         ## AF_INET6 when dual stack, else AF_INET; `sendTo` maps peers to it
    deadline: Deadline   ## the standing budget; an operation can only tighten it
    stop: nil CancelToken

proc `=destroy`*(u: UdpSocket) =
  ## The descriptor goes when the value does, so the error path that nobody
  ## wrote cannot leak it. The token reference goes with it.
  if u.fd >= 0: closeFd(u.fd)
  release(u.stop)

proc `=wasMoved`*(u: var UdpSocket) {.nodestroy, inline.} =
  ## -1, because the default 0 is stdin and a moved-from value must close
  ## nothing.
  u.fd = -1
  u.stop = nil

proc `=dup`*(u: UdpSocket): UdpSocket {.error.}
  ## Refused for the reason `=copy` gives.

proc `=copy`*(dest: var UdpSocket; src: UdpSocket) {.error.}
  ## Two values over one descriptor are two owners, and whichever dies first
  ## closes it under the other.

proc initUdp(fd, family: cint; stop: nil CancelToken): UdpSocket =
  # The child token is the socket's own: cancelling it ends this socket's
  # waits and leaves the parent alone. Like the token of `foundation/udp`, it
  # is not bound to the descriptor with `adoptFd`: a UDP socket is never shut
  # down.
  UdpSocket(fd: fd, family: family, deadline: never, stop: newCancelToken(stop))

proc isOpen*(u: UdpSocket): bool {.inline.} = u.fd >= 0
  ## False after `close` and in a moved-from value.

proc nativeHandle*(u: UdpSocket): cint {.inline.} = u.fd
  ## The descriptor, for socket options and for the multicast, broadcast and
  ## batch calls of `zal_net/raw/udp`. The `UdpSocket` still owns it.

proc cancelToken*(u: UdpSocket): nil CancelToken {.inline.} = u.stop
  ## Cancel it from any task to end this socket's waits. It ends them for
  ## good: every later operation raises `AbortedOperation`. A parked wait
  ## notices at its next poll, at most 200 ms later, and the descriptor stays
  ## open until `close`.

proc budget*(u: UdpSocket; dl: Deadline): Deadline {.inline.} =
  ## The deadline an operation runs under: the socket's, or a tighter one
  ## from the caller. A caller cannot widen it.
  earlier(u.deadline, dl)

proc renew*(u: var UdpSocket; deadline: Deadline) {.inline.} =
  ## Start a fresh standing budget. A long-lived socket serves many
  ## exchanges, and each needs its own or the first spends the allowance of
  ## all of them.
  u.deadline = deadline

proc close*(u: var UdpSocket) =
  ## Close now, before the end of the scope. A second call does nothing.
  if u.fd >= 0:
    closeFd(u.fd)
    u.fd = -1

proc localAddress*(u: UdpSocket): SocketAddress = fdLocal(u.fd)
  ## The address the socket is bound to: what a peer sends to.

proc remoteAddress*(u: UdpSocket): SocketAddress = fdRemote(u.fd)
  ## The peer `connect` set, or an empty address on an unconnected socket.

proc port*(u: UdpSocket): uint16 = fdLocal(u.fd).port
  ## The local port. A socket opened on port 0 has to tell its peers which
  ## one the kernel picked.

# ------------------------------------------------------- open and connect ---

proc openUdp*(port: uint16 = 0; host = ""; stop: nil CancelToken = nil;
              reusePort = false): UdpSocket {.raises.} =
  ## A socket bound to `host`, an address such as 127.0.0.1 or ::1, or to
  ## every address when it is empty. Port 0 asks the kernel for one. `stop`
  ## is the token of whoever may end this socket (a server, a scope); the
  ## socket gets a child of it, so cancelling the parent ends the socket and
  ## cancelling the socket leaves the parent alone.
  var s = default(rawudp.UdpSocket)
  checkIo(bindUdpInto(addr s, port, host, reusePort = reusePort))
  let family = s.family
  result = initUdp(rawudp.takeNativeHandle(addr s), family, stop)

proc connectTo(fd, family: cint; peer: SocketAddress): int =
  # connect(2) on the open socket. It sends nothing and does not wait, and
  # the bound port stays the same.
  result = 0
  let sa = forFamily(peer, family)
  if sockConnect(fd, unsafeAddr sa.ss, sa.len) != 0:
    result = -int(osLastError())

proc connect*(u: var UdpSocket; peer: SocketAddress) {.raises.} =
  ## Make `peer` the default peer: `send` goes there, and the kernel drops
  ## datagrams from anyone else before `recv` sees them. connect(2) on a
  ## datagram socket does not wait, so this is an ordinary procedure.
  if cancelled(u.stop): checkIo(ECancelled)
  checkIo(connectTo(u.fd, u.family, peer))

proc connect*(u: var UdpSocket; host: string; port: uint16;
              dl: Deadline = never) {.passive, raises.} =
  ## Resolve `host` and make the first of its addresses that the socket takes
  ## the default peer. `dl` bounds the lookup. Connecting sends nothing, so a
  ## peer that is not listening shows up later, as an error from a receive.
  var found = default(array[MaxAddrs, SockAddrBuf])
  let wanted = if u.family == AF_INET: AF_INET else: 0.cint
  let count = resolveAsync(host, port, SOCK_DGRAM, wanted, resolveBuffer(found),
                           budget(u, dl), u.stop)
  checkIo(count)
  if count == 0: checkIo(DnsNoAddresses)
  var firstError = 0
  for i in 0 ..< count:
    let code = connectTo(u.fd, u.family, fromRaw(found[i]))
    if code == 0: return
    if firstError == 0: firstError = code
  checkIo(firstError)

# ------------------------------------------------------------- datagrams ---

proc cancellation(u: UdpSocket): IoCancellation {.inline.} =
  # The socket's token in the owner slot, as `foundation/udp` passes its
  # own. UDP waits are not interrupted by a shutdown, so they poll in slices.
  ioCancellation(nil, u.stop)

proc socketFamily(u: UdpSocket): cint {.inline.} = u.family

proc checkSent(sent, total: int) {.raises.} =
  # A datagram goes out whole or not at all. A shorter count would be a cut
  # message, so it fails the way `net/udp` fails it.
  checkIo(sent)
  if sent != total: failIo(NoProgress)

template recvFrom*(u: var UdpSocket; dest: var openArray[byte]; peer: var SocketAddress;
                   dl: Deadline = never): int =
  ## One datagram into `dest` and its sender into `peer`, the address a reply
  ## goes to. Answers the datagram's length, cut to `dest.len`.
  block:
    let got = udpRecvFrom(nativeHandle(u), NoIdleLimitMs, dataPtr(dest), dest.len,
                          addr peer, budget(u, dl), cancellation(u))
    checkIo(got)
    got

template sendTo*(u: var UdpSocket; data: openArray[byte]; to: SocketAddress;
                 dl: Deadline = never) =
  ## `data` as one datagram to `to`, all of it or a raise. An IPv4 `to` on a
  ## dual-stack socket is mapped here, so the caller need not know the
  ## socket's family.
  block:
    let bytes: openArray[byte] = data
    checkSent(udpSendTo(nativeHandle(u), socketFamily(u), NoIdleLimitMs, dataPtr(bytes),
                        bytes.len, to, budget(u, dl), cancellation(u)), bytes.len)

template recv*(u: var UdpSocket; dest: var openArray[byte]; dl: Deadline = never): int =
  ## One datagram from the connected peer into `dest`: its length, cut to
  ## `dest.len`. recvfrom(2) without a source is recv(2), so this shares
  ## `recvFrom`'s loop.
  block:
    let got = udpRecvFrom(nativeHandle(u), NoIdleLimitMs, dataPtr(dest), dest.len,
                          nil, budget(u, dl), cancellation(u))
    checkIo(got)
    got

template send*(u: var UdpSocket; data: openArray[byte]; dl: Deadline = never) =
  ## `data` as one datagram to the connected peer, all of it or a raise. It
  ## needs its own loop: BSD refuses an address on a connected socket.
  block:
    let bytes: openArray[byte] = data
    checkSent(udpSendInline(nativeHandle(u), NoIdleLimitMs, dataPtr(bytes), bytes.len,
                            budget(u, dl), cancellation(u)), bytes.len)
