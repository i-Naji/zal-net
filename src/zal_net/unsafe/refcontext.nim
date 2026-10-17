## Borrow managed reference pointer bits without acquiring ownership. On the
## compiler pin a ref-to-pointer cast inside an object initializer increments
## ARC but loses the matching release. This restricted helper never changes the owner's count.
## Requires a proven non-nil Ref. The retained owner must outlive every
## context callback (trefcontext and ttlsref regressions).
proc borrowRefContext*[T: ref](owner: T): pointer {.inline.} =
  # Initialize with a known non-nil cell address; copyMem then replaces those
  # bits with its non-nil reference value. This avoids a false nil-proof error.
  result = cast[pointer](unsafeAddr owner)
  copyMem(addr result, unsafeAddr owner, sizeof(pointer))
