## Application datagrams with retained owners and enum errors.
## Every send emits one datagram, including an empty buffer. A zero receive
## count describes an empty datagram/window, never stream EOF. An empty receive
## window still consumes one datagram. Batch APIs stay explicit.
import zal_net/foundation/udp as owners
import zal_net/net/[address, failure]
import zal_net/rt/[time, cancel]
from zal_net/buffers import mutableWindow
from zal_net/errors import NoProgress, ResourceClosed
from zal_net/raw/udp import DefaultTimeoutMs

export address, time, cancel.CancelToken, failure.IoFailure, owners.DatagramInfo
type UdpSocket* = owners.UdpSocketRef

template bindUdp*(port: uint16 = 0; host = ""; timeoutMs = DefaultTimeoutMs;
                  reusePort = false): UdpSocket =
  block:
    let built = owners.bindUdpRef(port, host, timeoutMs, reusePort)
    checkIo(built.code)
    let socket = built.value
    if socket == nil: failIo(ResourceClosed)
    socket

template openUdp*(timeoutMs = DefaultTimeoutMs): UdpSocket =
  block:
    let built = owners.openUdpRef(timeoutMs)
    checkIo(built.code)
    let socket = built.value
    if socket == nil: failIo(ResourceClosed)
    socket

template connectUdp*(remote: SocketAddress; deadline: Deadline = never;
                     cancel: nil CancelToken = nil): UdpSocket =
  block:
    let built = owners.connectUdpRef(remote, deadline=deadline, tok=cancel)
    checkIo(built.code)
    let socket = built.value
    if socket == nil: failIo(ResourceClosed)
    socket

template connectUdp*(host: string; port: uint16; deadline: Deadline = never;
                     cancel: nil CancelToken = nil): UdpSocket =
  block:
    let built = owners.connectUdpRef(host, port, deadline=deadline, tok=cancel)
    checkIo(built.code)
    let socket = built.value
    if socket == nil: failIo(ResourceClosed)
    socket

# The initial UDP signature hits addArgsInstConverters on the pin when an
# array is passed with a named deadline (tapplicationudp guards the working form).
# Delay only byte-window binding;
# resolve module-qualified calls here while their bodies are typed. No casts,
# passive child wrappers or per-buffer specialization are needed.
template receiveRaw(socket: UdpSocket; bytes: var openArray[byte]; source: var SocketAddress;
                    until: Deadline; token: nil CancelToken): int =
  owners.recvFrom(socket, bytes, source, until, token)
template receiveRaw(socket: UdpSocket; bytes: var openArray[byte]; info: var DatagramInfo;
                    until: Deadline; token: nil CancelToken): int =
  owners.recvFrom(socket, bytes, info, until, token)
template sendRaw(socket: UdpSocket; bytes: openArray[byte]; to: SocketAddress;
                 until: Deadline; token: nil CancelToken): int =
  owners.sendTo(socket, bytes, to, until, token)
template readRaw(socket: UdpSocket; bytes: var openArray[byte];
                 until: Deadline; token: nil CancelToken): int =
  owners.recv(socket, bytes, until, token)
template writeRaw(socket: UdpSocket; bytes: openArray[byte];
                  until: Deadline; token: nil CancelToken): int =
  owners.send(socket, bytes, until, token)

proc saveReadFailure(socket: UdpSocket; count: int) =
  owners.recordRead(socket, if count < 0: count else: 0, max(count, 0))
proc saveWriteFailure(socket: UdpSocket; code, count: int) =
  owners.recordWrite(socket, code, max(count, 0))

template recvFrom*(socket: UdpSocket; buffer: typed;
                   source: var SocketAddress; deadline: Deadline = never;
                   cancel: nil CancelToken = nil): int {.untyped.} =
  block:
    let held = socket
    var window = mutableWindow(buffer)
    let until: Deadline = deadline
    let count = receiveRaw(held, window, source, until, cancel)
    saveReadFailure(held, count)
    checkIo(count)
    count

template recvFrom*(socket: UdpSocket; buffer: typed;
                   info: var DatagramInfo; deadline: Deadline = never;
                   cancel: nil CancelToken = nil): int {.untyped.} =
  ## Metadata reports truncation; a too-small receive window discards the tail.
  block:
    let held = socket
    var window = mutableWindow(buffer)
    let until: Deadline = deadline
    let count = receiveRaw(held, window, info, until, cancel)
    saveReadFailure(held, count)
    checkIo(count)
    count

template sendTo*(socket: UdpSocket; buffer: typed; to: SocketAddress;
                 deadline: Deadline = never; cancel: nil CancelToken = nil) {.untyped.} =
  block:
    let held = socket
    let data: openArray[byte] = buffer
    let until: Deadline = deadline
    let count = sendRaw(held, data, to, until, cancel)
    let code = if count < 0: count elif count != data.len: NoProgress else: 0
    saveWriteFailure(held, code, count)
    checkIo(code)

template read*(socket: UdpSocket; buffer: typed;
               deadline: Deadline = never; cancel: nil CancelToken = nil): int {.untyped.} =
  block:
    let held = socket
    var window = mutableWindow(buffer)
    let until: Deadline = deadline
    let count = readRaw(held, window, until, cancel)
    saveReadFailure(held, count)
    checkIo(count)
    count

template write*(socket: UdpSocket; buffer: typed;
                deadline: Deadline = never; cancel: nil CancelToken = nil) {.untyped.} =
  block:
    let held = socket
    let data: openArray[byte] = buffer
    let until: Deadline = deadline
    let count = writeRaw(held, data, until, cancel)
    let code = if count < 0: count elif count != data.len: NoProgress else: 0
    saveWriteFailure(held, code, count)
    checkIo(code)

template close*(socket: UdpSocket; deadline: Deadline = never) =
  checkIo(owners.close(socket, deadline))

proc localAddress*(socket: UdpSocket): SocketAddress = owners.localAddress(socket)
proc remoteAddress*(socket: UdpSocket): SocketAddress = owners.remoteAddress(socket)
proc lastReadFailure*(socket: UdpSocket): IoFailure {.inline.} = owners.lastReadFailure(socket)
proc lastWriteFailure*(socket: UdpSocket): IoFailure {.inline.} = owners.lastWriteFailure(socket)
