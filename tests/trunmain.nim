import std/[assertions, syncio]
import zal_net/rt, zal_net/raw/io, zal_net/rt/sync

var ran = false
proc forbidden() {.passive.} = assert false
proc main() {.passive.} =
  assert not runMain(forbidden())
  sleepMs(1)
  ran = true

assert runMain(main())
assert ran
assert not runMain(forbidden())
assert runtimeFinished()
assert not trySpawnTask(forbidden())
echo "PASS runMain parked root, placement rejection and nested/repeated entry"
