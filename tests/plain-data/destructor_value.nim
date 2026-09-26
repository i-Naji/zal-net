import zal_net/rt/sync
type Value = object
  owned: nil pointer
proc `=destroy`(v: Value) = discard
let rejected = newChannel[Value](1)
release(rejected)
