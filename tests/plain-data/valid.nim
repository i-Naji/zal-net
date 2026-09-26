import zal_net/rt/sync
type
  Id = distinct int
  Value = object
    id: Id
    nested: tuple[numbers: array[3, uint64], borrowed: nil pointer]
let accepted = newChannel[Value](2)
release(accepted)
