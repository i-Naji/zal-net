import zal_net/rt/sync
type Value = object
  case kind: bool
  of false: id: int
  of true: text: string
let rejected = newChannel[Value](1)
release(rejected)
