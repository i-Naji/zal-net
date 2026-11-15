## fillTo and sendAll end their wait when their token is cancelled, and run
## as before without one.
import std/[assertions, syncio, atomics]
import zal_net/rt, zal_net/raw/io
import zal_net/rt/cancel
import zal_net/raw/socket
import zal_net/relay

var cancelled = 0

proc cancelSoon(t: CancelToken) {.passive.} =
  parkUntil(afterMs(50))
  cancel t
  discard atomicFetchAdd(cancelled, 1, moRelease)

proc main() {.passive.} =
  let (near, far) = openPair()
  let r = newRelay(5000)
  assert r != nil
  if r == nil: quit "no relay"
  r.fd = near
  r.a.src = near

  # Bytes that are there: no token needed.
  var hello = [byte 1, 2, 3]
  discard writeSome(far, addr hello[0], hello.len)
  var res = 0
  var ok = false
  fillTo(r, addr r.a, 3, afterMs(2000), res, ok)
  assert ok and r.a.fill - r.a.off >= 3

  # Nothing more comes: the token ends the wait well before the deadline.
  let t = newCancelToken()
  assert trySpawnTask(cancelSoon(t))
  let bound = afterMs(2000)
  fillTo(r, addr r.a, 10, afterMs(5000), res, ok, t)
  assert not ok and res == ECancelled
  assert monoNow() < bound
  release t

  # sendAll with a token that stays live sends everything.
  let live = newCancelToken()
  var reply = [byte 9, 8, 7, 6]
  sendAll(r, near, addr reply[0], reply.len, res, ok, live)
  assert ok
  var got = default(array[4, byte])
  assert waitRead(far, addr got[0], 4, 2000) == 4 and got == reply
  release live

  closeRelay(r)
  closeFd(far)
  assert atomicLoad(cancelled, moAcquire) == 1
  echo "PASS fillTo and sendAll: buffered bytes, a cancelled wait, a live token"

assert runMain(main())
