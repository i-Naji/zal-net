from zal_net/io import IoResult, ioResult
from zal_net/buffers import dataPtr
## Application Unix streams. Stable owners, ordinary operations and ErrorCode raises.
## Use raw/unix for manual storage, native codes and engine integration.
## Owners stay on their creating loop; pending operations retain them.
import zal_net/foundation/unix as owners
import zal_net/foundation/unixlistener as listeners
import zal_net/net/failure
from zal_net/errors import NoProgress, ResourceClosed
import zal_net/rt/[time, cancel]

export time, cancel.CancelToken, failure.IoFailure

type
  UnixStream* = owners.UnixConnRef
  UnixListener* = listeners.UnixListenerRef

template connect*(path: string; deadline: Deadline = never;
                  cancel: nil CancelToken = nil): UnixStream =
  block:
    let outcome = owners.connectUnixConn(path, deadline=deadline, tok=cancel)
    checkIo(outcome.code)
    let value = outcome.value
    if value == nil:
      failIo(ResourceClosed)
    value

template listen*(path: string; backlog = 1024): UnixListener =
  block:
    let outcome = listeners.listenUnixRef(path, backlog)
    checkIo(outcome.code)
    let value = outcome.value
    if value == nil:
      failIo(ResourceClosed)
    value

template accept*(server: UnixListener; deadline: Deadline = never;
                 cancel: nil CancelToken = nil): UnixStream =
  block:
    let outcome = listeners.acceptConn(server, deadline=deadline, tok=cancel)
    checkIo(outcome.code)
    let value = outcome.value
    if value == nil:
      failIo(ResourceClosed)
    value

template read*(stream: UnixStream; buffer: var openArray[byte];
               deadline: Deadline = never; cancel: nil CancelToken = nil): int =
  block:
    let held = stream
    let count = owners.recvInto(held, buffer, deadline, cancel)
    owners.recordRead(held, if count < 0: count else: 0, if count > 0: count else: 0)
    checkIo(count)
    count

template write*(stream: UnixStream; buffer: openArray[byte];
                deadline: Deadline = never; cancel: nil CancelToken = nil) =
  block:
    let held = stream
    let bytes: openArray[byte] = buffer
    var outcome = ioResult(0, 0)
    owners.writeAllInto(held, dataPtr(bytes), bytes.len, deadline, cancel, outcome)
    checkIo(outcome.error)

template close*(stream: UnixStream; deadline: Deadline = never) =
  checkIo(owners.close(stream, deadline))

template close*(server: UnixListener; deadline: Deadline = never) =
  checkIo(listeners.close(server, deadline))

proc shutdownWrite*(stream: UnixStream) {.raises.} =
  checkIo(owners.shutdownWrite(stream))

proc path*(server: UnixListener): string {.inline.} = listeners.path(server)
proc lastReadFailure*(stream: UnixStream): IoFailure {.inline.} = owners.lastReadFailure(stream)
proc lastWriteFailure*(stream: UnixStream): IoFailure {.inline.} = owners.lastWriteFailure(stream)
proc deadline*(stream: UnixStream): Deadline {.inline.} = owners.deadline(stream)
proc renew*(stream: UnixStream; deadline: Deadline) {.inline.} = owners.renew(stream, deadline)
