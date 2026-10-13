## Owned sockets parked on their real deadline. Owner close interrupts the
## socket; runtime stop shuts down every socket recorded here, once.
import std/atomics
from zal_net/private/sys/sock import sockShutdown

const ParkedMax* = 1 shl 16

var gParked: array[ParkedMax, int]

proc enterParked*(fd: cint): bool {.sync.} =
  ## False for a descriptor the table cannot hold: such a park keeps slicing.
  if fd < 0 or fd >= ParkedMax: return false
  {.cast(assumeSync).}:
    discard atomicFetchAdd(gParked[fd], 1, moSequentiallyConsistent)
  result = true

proc leaveParked*(fd: cint) {.sync.} =
  {.cast(assumeSync).}:
    discard atomicFetchSub(gParked[fd], 1, moSequentiallyConsistent)

proc interruptParked*() {.sync.} =
  {.cast(assumeSync).}:
    var fd = 0
    while fd < ParkedMax:
      if atomicLoad(gParked[fd], moSequentiallyConsistent) > 0: discard sockShutdown(cint(fd), 2)
      fd = fd + 1
