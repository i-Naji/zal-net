import zal_net/rt/sync
type Value = proc (): int {.closure.}
let rejected = newPromise[Value]()
release(rejected)
