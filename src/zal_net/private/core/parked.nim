## Owned sockets parked on their real deadline. Owner close interrupts the
## socket; runtime stop shuts down every socket recorded here, once.
import std/atomics
from zal_net/private/sys/sock import sockShutdown
import zal_net/private/sys/posix
import zal_net/private/sharedmem

const ParkedLimit = 1 shl 21

var gParked: nil ptr UncheckedArray[int]
var gParkedCap: int

proc newFdTable*(cap: var int): nil ptr UncheckedArray[int] =
  ## One zeroed slot per descriptor; pages are backed only when used.
  result = nil
  var soft = 0
  var hard = 0
  if not fdLimits(soft, hard): soft = 0
  let size = min(max(soft, 1 shl 16), ParkedLimit)
  let table = zeroedShared(size * sizeof(int))
  if table != nil:
    result = cast[ptr UncheckedArray[int]](table)
    cap = size

proc initParked*() {.sync.} =
  ## Once, before any park.
  {.cast(assumeSync).}:
    if gParked == nil: gParked = newFdTable(gParkedCap)

proc enterParked*(fd: cint): bool {.sync.} =
  ## False for a descriptor the table cannot hold: such a park keeps slicing.
  {.cast(assumeSync).}:
    let table = gParked
    if table == nil or fd < 0 or fd >= gParkedCap: return false
    discard atomicFetchAdd(table[fd], 1, moSequentiallyConsistent)
  result = true

proc leaveParked*(fd: cint) {.sync.} =
  {.cast(assumeSync).}:
    let table = gParked
    if table != nil: discard atomicFetchSub(table[fd], 1, moSequentiallyConsistent)

proc interruptParked*() {.sync.} =
  {.cast(assumeSync).}:
    let table = gParked
    if table == nil: return
    var fd = 0
    while fd < gParkedCap:
      if atomicLoad(table[fd], moSequentiallyConsistent) > 0: discard sockShutdown(cint(fd), 2)
      fd = fd + 1
