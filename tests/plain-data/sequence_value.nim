import zal_net/rt/sync
let rejected = newChannel[seq[int]](1)
release(rejected)
