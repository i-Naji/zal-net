import zal_net/rt/sync
type Value = ref object
  id: int
let rejected = newChannel[Value](1)
release(rejected)
