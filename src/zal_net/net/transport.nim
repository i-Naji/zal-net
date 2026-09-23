## Retained transport adapters for composing protocol libraries.
import std/assertions
import zal_net/unsafe/streamview
import zal_net/[buffers, errors]
import zal_net/rt/[cancel, time]
export streamview.StreamOps, time, errors

# Retained adapters own callback storage and keep the concrete owner alive.
# The type-erased context is constructed from that same owner, never a caller
# supplied pointer. Raw borrowed views belong only in unsafe integration code.
import zal_net/unsafe/refcontext
import zal_net/rt
import zal_net/ownership

type
  TransportControl* = object
    close*: proc (ctx: pointer): int {.nimcall, passive.}
      ## Complete cleanup before returning, including when reporting failure.
    dispose*: proc (ctx: pointer): int {.nimcall.}
    checkTransfer*: proc (ctx: pointer): int {.nimcall.}
      ## Nonmutating admission check: reject pending operations before transfer.
  KeepAlive[T] = ref object of RootObj
    value: T
  TransportObj = object
    owner: nil RootRef
    context: nil pointer
    operations: StreamOps
    control: TransportControl
    life: OwnerLife
    active: bool
  Transport* = ref TransportObj
  TransportResult* = object
    value*: nil Transport
    code*: int

proc `=destroy`(transport: var TransportObj) =
  # Concrete owner destruction is responsible for quiescent native disposal.
  # No passive callback or runtime operation is entered by a destructor.
  transport.owner = nil

proc retainTransport*[T](owner: T; operations: StreamOps;
                         control: TransportControl): Transport =
  ## Callbacks receive the opaque reference representation: cast ctx to T,
  ## never ptr T or ptr typeof(owner[]). Each callback must preserve its owner.
  when not (T is ref):
    {.error: "retained transport requires a reference owner".}
  let keep = KeepAlive[T](value: owner)
  let context = borrowRefContext(owner)
  result = Transport(owner: RootRef(keep), context: context, operations: operations,
                     control: control, active: true)
  initOwnerLife(result.life)

proc isOpen*(transport: Transport): bool {.inline.} =
  state(transport.life) == ownerOpen

proc borrow*(transport: Transport): StreamView =
  ## Unsafe lifetime escape: the returned view borrows the adapter itself.
  ## Retain transport through every use. Safe operations below do this for you.
  if state(transport.life) != ownerClosed:
    let context = transport.context
    if context != nil:
      return unsafeBorrowStream(context, addr transport.operations)
  result = default(StreamView)

proc canTransfer*(transport: Transport): int =
  if state(transport.life) != ownerOpen: return ResourceClosed
  if not isIdle(transport.life): return ResourceBusy
  let context = transport.context
  if context == nil: return ResourceClosed
  result = transport.control.checkTransfer(context)

proc takeTransport*(transport: Transport): TransportResult =
  result = default(TransportResult)
  result.code = canTransfer(transport)
  if result.code == 0:
    let taken = Transport(owner: transport.owner, context: transport.context,
      operations: transport.operations, control: transport.control,
      active: true)
    initOwnerLife(taken.life)
    result.code = beginTransfer(transport.life)
    if result.code == 0: result.value = taken

proc dispose*(transport: Transport): int =
  if state(transport.life) == ownerClosed: return 0
  result = beginClose(transport.life, true, true)
  if result != 0: return ResourceBusy
  let context = transport.context
  if context == nil: result = ResourceClosed
  else: result = transport.control.dispose(context)
  finishInterrupt(transport.life)
  if result == 0: markClosed(transport.life)
  else: reopenRejectedClose(transport.life)

proc finishOperation(transport: Transport; write: bool) =
  endBorrow(transport.life, write)
  signalIdle(transport.life)

proc gate(transport: Transport): ptr OwnerLife = addr transport.life

proc startClose(transport: Transport): int = beginClose(transport.life, true)
proc closing(transport: Transport): bool = state(transport.life) != ownerOpen

proc finishClose(transport: Transport) =
  markClosed(transport.life)

proc close*(transport: Transport): int {.passive.} =
  block:
    let held = transport
    var code = startClose(held)
    if code == ResourceClosed:
      code = drainClose(gate(held), never)
    elif code == 0:
      let context = held.context
      if context != nil and not isIdle(held.life): held.operations.interrupt(context)
      finishInterrupt(held.life)
      while not claimOwnerCleanup(held.life):
        drainBorrowers(gate(held))
        yieldNow()
      if context != nil: code = held.control.close(context)
      finishClose(held)
    code

template recvInto*(transport: Transport; p: pointer; n: int;
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  block:
    let held = transport
    var count = beginBorrow(gate(held)[], false)
    if count == 0:
      defer: finishOperation(held, false)
      count = recvInto(borrow(held), p, n, deadline, tok)
    count

template sendFrom*(transport: Transport; p: pointer; n: int;
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  block:
    let held = transport
    var count = beginBorrow(gate(held)[], true)
    if count == 0:
      defer: finishOperation(held, true)
      count = sendFrom(borrow(held), p, n, deadline, tok)
    count

template recvInto*(transport: Transport; buffer: var openArray[byte];
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  recvInto(transport, dataPtr(buffer), buffer.len, deadline, tok)

template sendFrom*(transport: Transport; buffer: openArray[byte];
                   deadline: Deadline = never; tok: nil CancelToken = nil): int =
  sendFrom(transport, dataPtr(buffer), buffer.len, deadline, tok)

proc interrupt*(transport: Transport) =
  if beginControl(transport.life) != 0: return
  interrupt(borrow(transport))
  endControl(transport.life)
  signalIdle(transport.life)
proc shutdownWrite*(transport: Transport) =
  if beginBorrow(transport.life, true) != 0: return
  shutdownWrite(borrow(transport))
  finishOperation(transport, true)

from zal_net/io import IoResult
proc writeAll*(transport: Transport; p: pointer; n: int;
               deadline: Deadline = never; tok: nil CancelToken = nil): IoResult {.passive.} =
  result = default(IoResult)
  result.error = beginBorrow(gate(transport)[], true)
  if result.error != 0: return
  defer: finishOperation(transport, true)
  if n < 0:
    result.error = InvalidInput
    return
  let view = borrow(transport)
  retain(tok)
  defer: release(tok)
  while result.bytes < n:
    let position = offset(bytesPtr(p), result.bytes)
    let count = sendFrom(view, position, n - result.bytes, deadline, tok)
    if count <= 0:
      result.error = if count < 0: count else: NoProgress
      break
    result.bytes += count

template writeAll*(transport: Transport; buffer: openArray[byte];
                   deadline: Deadline = never; tok: nil CancelToken = nil): IoResult =
  block:
    let held = transport
    let bytes: openArray[byte] = buffer
    writeAll(held, dataPtr(bytes), bytes.len, deadline, tok)
