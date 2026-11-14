import zal_net/rt/sync
type
  Parent = object of RootObj
    text: string
  Value = object of Parent
    id: int
let rejected = newChannel[Value](1)
release(rejected)
