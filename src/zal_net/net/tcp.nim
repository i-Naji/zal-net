from zal_net/io import IoResult, ioResult
from zal_net/buffers import dataPtr
## Application TCP. Stable owners, ordinary operations and ErrorCode raises.
## Use raw/tcp for manual storage, native codes and engine integration.
## Pending operations retain their owner. Admission is synchronized across
## pool workers.
import zal_net/foundation/tcp as owners
import zal_net/foundation/tcplistener as listeners
import zal_net/net/address
import zal_net/net/failure
from zal_net/errors import NoProgress, ResourceClosed
import zal_net/rt/[time, cancel]

export time, cancel.CancelToken, failure.IoFailure

type
  TcpStream* = owners.TcpConnRef
  TcpListener* = listeners.TcpListenerRef

template connect*(host: string; port: uint16; deadline: Deadline = never;
                  cancel: nil CancelToken = nil): TcpStream =
  block:
    let outcome = owners.connectTcpConn(host, port, deadline=deadline, tok=cancel)
    checkIo(outcome.code)
    let value = outcome.value
    if value == nil:
      failIo(ResourceClosed)
    value

template connect*(address: SocketAddress; deadline: Deadline = never;
                  cancel: nil CancelToken = nil): TcpStream =
  block:
    let outcome = owners.connectTcpConn(address, deadline=deadline, tok=cancel)
    checkIo(outcome.code)
    let value = outcome.value
    if value == nil:
      failIo(ResourceClosed)
    value

template listen*(port: uint16; host = ""; backlog = 1024): TcpListener =
  block:
    let outcome = listeners.listenTcpRef(port, host, backlog)
    checkIo(outcome.code)
    let value = outcome.value
    if value == nil:
      failIo(ResourceClosed)
    value

template accept*(server: TcpListener; deadline: Deadline = never;
                 cancel: nil CancelToken = nil): TcpStream =
  block:
    let outcome = listeners.acceptConn(server, deadline=deadline, tok=cancel)
    checkIo(outcome.code)
    let value = outcome.value
    if value == nil:
      failIo(ResourceClosed)
    value

template read*(stream: TcpStream; buffer: var openArray[byte];
               deadline: Deadline = never; cancel: nil CancelToken = nil): int =
  block:
    let held = stream
    let count = owners.recvInto(held, buffer, deadline, cancel)
    owners.recordRead(held, if count < 0: count else: 0, if count > 0: count else: 0)
    checkIo(count)
    count

template write*(stream: TcpStream; buffer: openArray[byte];
                deadline: Deadline = never; cancel: nil CancelToken = nil) =
  block:
    let held = stream
    let bytes: openArray[byte] = buffer
    var outcome = ioResult(0, 0)
    owners.writeAllInto(held, dataPtr(bytes), bytes.len, deadline, cancel, outcome)
    checkIo(outcome.error)

template close*(stream: TcpStream; deadline: Deadline = never) =
  checkIo(owners.close(stream, deadline))

template close*(server: TcpListener; deadline: Deadline = never) =
  checkIo(listeners.close(server, deadline))

proc shutdownWrite*(stream: TcpStream) {.raises.} =
  checkIo(owners.shutdownWrite(stream))

proc port*(server: TcpListener): uint16 {.inline.} = listeners.port(server)
proc lastReadFailure*(stream: TcpStream): IoFailure {.inline.} = owners.lastReadFailure(stream)
proc lastWriteFailure*(stream: TcpStream): IoFailure {.inline.} = owners.lastWriteFailure(stream)
