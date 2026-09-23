## A borrowed byte-stream adapter for runtime composition. The context and
## operation table must outlive every pending operation. Copying this small view
## does not copy or retain its owner. Views never close or dispose resources.
## Callbacks run on the caller's loop; they must honor the supplied deadline and
## cancellation token without terminal interruption of their owner. Callbacks
## borrow the token; StreamView retains it until the operation returns.
import zal_net/rt/time
import zal_net/errors
import zal_net/rt/cancel
import zal_net/buffers
export time, errors

type
  StreamOps* = object
    recv*: proc (ctx: pointer; buf: pointer; count: int; until: Deadline;
                 tok: nil CancelToken): int {.nimcall, passive.}
    send*: proc (ctx: pointer; buf: pointer; count: int; until: Deadline;
                 tok: nil CancelToken): int {.nimcall, passive.}
    shutdownWrite*: proc (ctx: pointer) {.nimcall.}
    interrupt*: proc (ctx: pointer) {.nimcall.}

  StreamOpsPtr* = ptr StreamOps
  StreamView* = object
    context: nil pointer
    ops: nil StreamOpsPtr

proc unsafeBorrowStream*(context: pointer; ops: StreamOpsPtr): StreamView =
  StreamView(context: context, ops: ops)

proc isOpen*(s: StreamView): bool {.inline.} = s.ops != nil and s.context != nil

proc recvInto*(s: StreamView; p: pointer; n: int; deadline = never;
               tok: nil CancelToken = nil): int {.passive.} =
  if n < 0: return InvalidInput
  if n == 0: return 0
  retain(tok)
  defer: release(tok)
  let table = s.ops
  let context = s.context
  if table == nil or context == nil: return ResourceClosed
  if cancelled(tok): return ECancelled
  result = table.recv(context, p, n, deadline, tok)

proc sendFrom*(s: StreamView; p: pointer; n: int; deadline = never;
               tok: nil CancelToken = nil): int {.passive.} =
  if n < 0: return InvalidInput
  if n == 0: return 0
  retain(tok)
  defer: release(tok)
  let table = s.ops
  let context = s.context
  if table == nil or context == nil: return ResourceClosed
  if cancelled(tok): return ECancelled
  result = table.send(context, p, n, deadline, tok)

template recvInto*(s: StreamView; buf: var openArray[byte]; deadline: Deadline = never;
                   tok: nil CancelToken = nil): int =
  recvInto(s, dataPtr(buf), buf.len, deadline, tok)

template sendFrom*(s: StreamView; buf: openArray[byte]; deadline: Deadline = never;
                   tok: nil CancelToken = nil): int =
  sendFrom(s, dataPtr(buf), buf.len, deadline, tok)

proc shutdownWrite*(s: StreamView) =
  let table = s.ops
  let context = s.context
  if table != nil and context != nil: table.shutdownWrite(context)

proc interrupt*(s: StreamView) =
  let table = s.ops
  let context = s.context
  if table != nil and context != nil: table.interrupt(context)
