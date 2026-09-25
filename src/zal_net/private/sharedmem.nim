## Plain shared storage for library-owned workers. These allocations may be
## released by a different thread; they never contain managed Nim values.
import std/syncio
proc zeroedShared*(size: int): nil pointer {.inline.} =
  proc calloc(count, size: csize_t): nil pointer {.importc, header: "<stdlib.h>".}
  result = calloc(1, csize_t(max(1, size)))
proc requireShared*(size: int): pointer =
  let memory = zeroedShared(size)
  if memory == nil: quit "zal-net: shared allocation failed"
  result = memory
proc freeShared*(memory: nil pointer) {.importc: "free", header: "<stdlib.h>".}
