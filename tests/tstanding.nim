## A standing deadline bounds every read and write besides their own.
import std/[assertions, syncio]
import zal_net
import zal_net/rt/cancel as cancellation

proc exercise() {.passive, raises.} =
  let server = listen(0, "127.0.0.1")
  defer: server.close()
  let client = connect("127.0.0.1", server.port, deadline=afterMs(2000))
  defer: client.close()
  let peer = server.accept(deadline=afterMs(2000))
  defer: peer.close()
  assert client.deadline == never, "no standing deadline at first"

  var bytes = default(array[4, byte])
  client.renew(afterMs(100))
  let started = monoNow()
  try:
    discard client.read(bytes)
    assert false, "a silent peer must time out"
  except ErrorCode as error:
    assert error == TimeoutError, "the standing deadline expires the read"
  let waited = millisUntil(monoNow(), started)
  assert waited >= 80 and waited <= 1500, "the read waited for the standing deadline"

  # The earlier of the two wins.
  client.renew(afterMs(5000))
  let early = monoNow()
  try:
    discard client.read(bytes, deadline=afterMs(50))
    assert false
  except ErrorCode as error:
    assert error == TimeoutError
  assert millisUntil(monoNow(), early) <= 1500, "a per-call deadline still tightens it"

  client.renew(never)
  assert client.deadline == never, "never clears it"
  peer.write([1'u8, 2, 3])
  assert client.read(bytes, deadline=afterMs(2000)) == 3, "reads work again"

  # It bounds writes too, and an expired one fails at once.
  peer.renew(afterMs(-1))
  try:
    peer.write([4'u8])
    assert false, "an expired standing deadline fails the write"
  except ErrorCode as error:
    assert error == TimeoutError

proc main() {.passive.} =
  try:
    exercise()
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false
  assert cancellation.liveCancelTokens() == 0
  echo "PASS standing deadline on reads and writes, cleared by never"

assert runMain(main())
