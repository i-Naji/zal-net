## Foreign producers hand messages to the process runner, never poll std lanes.
import std/[atomics, assertions, syncio]
import zal_net/rt
import zal_net/private/sys/threads

const Producers = 4
const Each = 200
var finished, submitted, destroyed: int
type PayloadObj = object
  number: int
proc `=destroy`(payload: var PayloadObj) =
  discard atomicFetchAdd(destroyed, 1, moRelease)
type Payload = ref PayloadObj

proc child(payload: sink Payload) {.passive.} =
  let expected = payload.number
  parkUntil(afterMs(1))
  assert payload.number == expected
  discard atomicFetchAdd(finished, 1, moRelease)

proc producer(arg: nil pointer) {.nimcall.} =
  for i in 0..<Each:
    let value = Payload(number: i)
    assert trySpawnTask(child(value))
    discard atomicFetchAdd(submitted, 1, moRelease)

proc root() {.passive.} =
  let deadline = afterMs(15000)
  while atomicLoad(finished, moAcquire) != Producers * Each:
    assert monoNow() < deadline
    parkUntil(afterMs(1))

initRuntime()
var producers = default(array[Producers, ThreadHandle])
for i in 0..<Producers: assert startJoinable(producers[i], producer, nil)
assert runMain(root())
for i in 0..<Producers: assert joinThread(producers[i])
assert runtimeFinished()
assert atomicLoad(submitted, moAcquire) == Producers * Each
assert atomicLoad(destroyed, moAcquire) == Producers * Each
echo "PASS 800 foreign submissions, retained captures and joined std teardown"
