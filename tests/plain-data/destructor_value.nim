import zal_net/rt/sync
type Value = object
  owned: nil pointer
proc `=destroy`(v: Value) = discard
proc `=wasMoved`(v: var Value) {.nodestroy, inline.} = discard
let rejected = newChannel[Value](1)
release(rejected)
