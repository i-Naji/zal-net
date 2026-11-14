import zal_net/rt/sync
type Value = distinct string
let rejected = newPromise[Value]()
release(rejected)
