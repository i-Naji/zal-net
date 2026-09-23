## Protocol-neutral operation results. A failed write may have made progress.
import zal_net/[errors, buffers]
import zal_net/rt/[time, cancel]
export errors, time, cancel

type IoResult* = object
  bytes*: int
  error*: int                    ## zero on success; native/library code otherwise

## Use this constructor in nested templates: default(IoResult) exposes field
## names to parameter substitution in the pinned compiler.
proc ioResult*(transferred, code: int): IoResult {.inline.} =
  IoResult(bytes: transferred, error: code)

proc fromCount*(count: int): IoResult {.inline.} =
  if count < 0: IoResult(error: count)
  else: IoResult(bytes: count)

proc failure*(outcome: IoResult): IoFailure {.inline.} =
  IoFailure(code: outcome.error, transferred: outcome.bytes)

template readSome*(stream: untyped; buffer: var openArray[byte];
                   deadline: Deadline = never; cancel: nil CancelToken = nil): untyped =
  block:
    mixin recvInto
    fromCount(recvInto(stream, buffer, deadline, cancel))

template writeSome*(stream: untyped; buffer: openArray[byte];
                    deadline: Deadline = never; cancel: nil CancelToken = nil): untyped =
  block:
    mixin sendFrom
    fromCount(sendFrom(stream, buffer, deadline, cancel))
