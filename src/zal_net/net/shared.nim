## Immutable read-mostly app state. Plain values are copied at creation and
## read by value; callers never receive a mutable storage pointer. Reference
## ownership uses the compiler's validated atomicArc model.
import zal_net/plain

type
  SharedObj[T] = object
    value: T
  Shared*[T] = ref SharedObj[T]

proc newShared*[T](value: T): Shared[T] =
  requirePlainData(T)
  result = Shared[T]()
  result.value = value

proc read*[T](shared: Shared[T]): T {.inline.} =
  requirePlainData(T)
  shared.value
