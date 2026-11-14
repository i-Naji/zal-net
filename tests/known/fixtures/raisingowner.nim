## Deliberately separate from c42: the failure requires a module boundary.
type Owner* = ref object
  value*: int

type OwnerResult = object
  value: nil Owner
  code: int

proc buildOwner(value: int): OwnerResult =
  result = default(OwnerResult)
  if value < 0:
    result.code = -1
  else:
    result.value = Owner(value: value)

proc fail() {.raises, noreturn.} = raise ValueError

proc makeOwner*(value: int): Owner {.raises.} =
  let outcome = buildOwner(value)
  if outcome.code < 0:
    fail()
  let owner = outcome.value
  if owner == nil:
    fail()
  result = owner
