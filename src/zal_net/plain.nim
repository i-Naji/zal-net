## Compile-time contract for values copied bytewise across thread boundaries.
## Pointers are borrowed: their targets must outlive every receiver.
## There is no runtime inspection or sample-value initialization.
import std/typetraits

template isPlainData*[T](valueType: typedesc[T]): bool =
  supportsCopyMem(T)

template requirePlainData*[T](valueType: typedesc[T]) =
  when not supportsCopyMem(T):
    {.error: "cross-thread byte copies require plain data (no managed fields or closures)".}
