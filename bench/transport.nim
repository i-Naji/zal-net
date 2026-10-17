{.feature: "assumeSync".}
# Construction and disposal only; no sockets or pool workers.
import std/[assertions, syncio]
import zal_net/net/transport
import zal_net/rt/cancel

const Iterations = 200_000
var destroyed: int
type OwnerObj = object
  value: int
type Owner = ref OwnerObj
proc `=destroy`(value: var OwnerObj) = inc destroyed
proc read(ctx: pointer; p: pointer; n: int; d: Deadline; tok: nil CancelToken): int {.passive.} = 0
proc write(ctx: pointer; p: pointer; n: int; d: Deadline; tok: nil CancelToken): int {.passive.} = n
proc control(ctx: pointer) = discard
proc dispose(ctx: pointer): int = 0
proc close(ctx: pointer): int {.passive.} = 0
proc checkTransfer(ctx: pointer): int = 0

proc sample(): int64 =
  let start = monoNow()
  for i in 0..<Iterations:
    let owner = Owner(value: i)
    let transport = retainTransport(owner,
      StreamOps(recv: read, send: write, shutdownWrite: control, interrupt: control),
      TransportControl(close: close, dispose: dispose, checkTransfer: checkTransfer))
    assert dispose(transport) == 0
  result = int64(monoNow()) - int64(start)

for run in 0..<5:
  let elapsed = sample()
  echo Iterations, " constructions; ns/op=", elapsed div Iterations
assert destroyed == 5 * Iterations
