## Deterministic final-release/cancel interleaving; check_cancel_release.py
## also runs this with an isolated reproduction of the old release ordering.
import std/[assertions, syncio]
import zal_net/private/core/cancelstate

proc cancelParent(parent: CancelToken) {.nimcall.} =
  onFinalChildRelease = nil
  cancel(parent)

let before = liveCancelTokens()
let parent = newCancelToken()
let child = newCancelToken(parent)
onFinalChildRelease = cancelParent
release(child)
assert cancelled(parent)
release(parent)
assert liveCancelTokens() == before
echo "PASS final child release interleaved with parent cancellation"
