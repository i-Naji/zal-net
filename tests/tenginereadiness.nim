## Registration retirement retains the descriptor until the waiter completes.
import std/[assertions, syncio]
import zal_net/rt
import zal_net/raw/io
import zal_net/private/sys/sock
import zal_net/foundation/readiness

proc main() {.passive.} =
  let ready = newReadiness()
  for cycle in 0..<128:
    var pair = [-1.cint, -1.cint]
    assert sockPair(addr pair[0]) == 0
    assert sockSetNonblock(pair[0], true) and sockSetNonblock(pair[1], true)
    assert watch(ready, pair[0], uint64(cycle))
    assert not watch(ready, pair[0], uint64(cycle))
    var data = 19'u8
    assert writeSome(pair[1], addr data, 1) == 1
    let event = nextReady(ready, afterMs(2000))
    let registration = event.registration
    assert registration != nil and event.tag == uint64(cycle)
    if registration != nil:
      assert nextReady(ready, afterMs(1)).registration == nil, "one event before acknowledgement"
      assert readSome(pair[0], addr data, 1) == 1 and data == 19
      acknowledge(registration)
      data = 23
      assert writeSome(pair[1], addr data, 1) == 1
      let rearmed = nextReady(ready, afterMs(2000))
      assert rearmed.registration == registration and rearmed.tag == uint64(cycle),
        "acknowledgement permits exactly one more readiness event"
      assert nextReady(ready, afterMs(1)).registration == nil
      assert readSome(pair[0], addr data, 1) == 1 and data == 23
      # Retire without acknowledging the second event: join must also drain
      # a watcher waiting on its consumer, not only one polling its socket.
    let retired = retire(ready, pair[0])
    assert retired != nil
    assert retire(ready, pair[0]) == nil
    if retired != nil:
      assert not active(retired)
      join(retired)
      assert completed(retired)
    closeFd(pair[0])
    closeFd(pair[1])
  # A queued event is invalidated before the same logical tag is reused.
  var pair = [-1.cint, -1.cint]
  assert sockPair(addr pair[0]) == 0
  assert sockSetNonblock(pair[0], true)
  assert watch(ready, pair[0], 0)
  var data = 1'u8
  assert writeSome(pair[1], addr data, 1) == 1
  parkUntil(afterMs(20))
  let retired = retireAll(ready)
  for registration in retired: join(registration)
  assert nextReady(ready, afterMs(0)).registration == nil
  discardReady(ready)
  closeFd(pair[0])
  closeFd(pair[1])
  requestStop()
  assert sockPair(addr pair[0]) == 0
  assert not watch(ready, pair[0], 99)
  assert writeSome(pair[1], addr data, 1) == 1
  assert readSome(pair[0], addr data, 1) == 1, "rejected registration preserves descriptor ownership"
  closeFd(pair[0])
  closeFd(pair[1])
  echo "PASS 128 standard readiness retirement/reuse cycles and stale-event rejection"

assert runMain(main())
