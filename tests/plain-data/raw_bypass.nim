import zal_net/rt/sync
let raw = newChan(sizeof(string), 1)
let rejected = Channel[string](raw: raw)
discard trySend(rejected, "owned memory")
release(raw)
