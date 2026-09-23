## Compile-time contract for values copied bytewise across thread boundaries.
## Pointers are borrowed: their targets must outlive every receiver.
## There is no runtime inspection or sample-value initialization. Values must
## not have ownership/copy/destruction hooks: this pin does not expose every
## hook to plugins, so that additional requirement remains a caller contract.
template plainType[T](valueType: typedesc[T]; sequenceType: typedesc[seq[byte]];
                      stringType: typedesc[string]): bool {.plugin: "private/plaincheck".}

template isPlainData*[T](valueType: typedesc[T]): bool =
  plainType(T, seq[byte], string)

template requirePlainData*[T](valueType: typedesc[T]) =
  when not isPlainData(T):
    {.error: "cross-thread byte copies require plain data (no managed fields or closures)".}
