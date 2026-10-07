{.feature: "assumeSync".}
## The root is started from regular application code with local arguments.
import std/[assertions, syncio]
import zal_net/private/sys/threads
import zal_net/rt, zal_net/raw/io

var observed = 0
proc forbidden() {.passive.} = assert false
proc foreignEntry(arg: nil pointer) {.nimcall.} =
  assert not runMain(forbidden()), "foreign thread must submit, not enter runtime"
proc root(value: int) {.passive.} =
  sleepMs(1)
  observed = value

proc application() =
  var foreign = default(ThreadHandle)
  assert startJoinable(foreign, foreignEntry, nil)
  assert joinThread(foreign)
  let localValue = 73
  assert runMain(root(localValue))
  assert observed == localValue

application()
echo "PASS regular application passes local arguments to its passive root"
