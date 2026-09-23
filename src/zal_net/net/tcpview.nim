## Retained transport adapter for a TCP owner. Callback storage and the owner
## remain alive for the adapter lifetime.
import zal_net/foundation/tcp, zal_net/net/transport
import zal_net/rt/cancel
import zal_net/rt/time
import zal_net/unsafe/refcontext

proc connection(context: pointer): TcpConnRef {.inline.} =
  ## Only contexts created by retainTransport are valid; never an arbitrary cast.
  cast[TcpConnRef](context)

proc read(context: pointer; p: pointer; n: int; deadline: Deadline;
          tok: nil CancelToken): int {.nimcall, passive.} =
  let held = connection(context)
  result = recvInto(held, p, n, deadline, tok)

proc write(context: pointer; p: pointer; n: int; deadline: Deadline;
           tok: nil CancelToken): int {.nimcall, passive.} =
  let held = connection(context)
  result = sendFrom(held, p, n, deadline, tok)

proc halfClose(context: pointer) {.nimcall.} =
  let held = connection(context)
  discard shutdownWrite(held)

proc abort(context: pointer) {.nimcall.} =
  let held = connection(context)
  discard interrupt(held)

proc closeView(context: pointer): int {.nimcall, passive.} =
  let held = connection(context)
  result = close(held)

proc dispose(context: pointer): int {.nimcall.} =
  let held = connection(context)
  result = closeNow(held)

var operations = StreamOps(recv: read, send: write, shutdownWrite: halfClose,
                          interrupt: abort)


proc transferCheck(context: pointer): int {.nimcall.} =
  let held = connection(context)
  if not quiescent(held): return ResourceBusy
  if state(held) != ownerOpen: return ResourceClosed
  result = 0

proc tcpTransport*(owner: TcpConnRef): Transport =
  retainTransport(owner, operations, TransportControl(close: closeView,
    dispose: dispose, checkTransfer: transferCheck))
