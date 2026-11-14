import zal_net/rt/sync
type Value = object
  nested: tuple[id: int, text: string]
let rejected = newPromise[Value]()
release(rejected)
