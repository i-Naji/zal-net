## Deadlines on a Conn: the standing one from `renew`, a tighter one per call,
## expired ones on ready sockets, a write the peer never drains, and a
## deadline argument evaluated once.
import std/[assertions, syncio]
import zal_net/rt
import zal_net/rt/sync
import zal_net/conn
import zal_net/net/options

type Shared = ref object
  done: Event

proc observer(shared: Shared) {.passive.} =
  setEvent(addr shared.done)

proc countedDeadline(calls: var int; ms: int): Deadline =
  inc calls
  afterMs(ms)

proc main() {.passive.} =
  try:
    var listener = listen(0, "127.0.0.1")
    var client = connect("127.0.0.1", listener.port, afterMs(2000))
    var peer = accept(listener, afterMs(2000))
    var bytes = default(array[4, byte])

    # The standing deadline bounds a read that names none.
    client.renew afterMs(100)
    let started = monoNow()
    var timedOut = false
    try: discard client.read(bytes)
    except ErrorCode as error: timedOut = error == TimeoutError
    assert timedOut, "the standing deadline expires the read"
    let waited = millisUntil(monoNow(), started)
    assert waited >= 80 and waited <= 1500, "the read waited for the standing deadline"

    # A per-call deadline tightens it; it cannot widen it.
    client.renew afterMs(5000)
    let early = monoNow()
    timedOut = false
    try: discard client.read(bytes, afterMs(50))
    except ErrorCode as error: timedOut = error == TimeoutError
    assert timedOut and millisUntil(monoNow(), early) <= 1500
    client.renew afterMs(30)
    timedOut = false
    try: discard client.read(bytes, afterMs(5000))
    except ErrorCode as error: timedOut = error == TimeoutError
    assert timedOut, "a later per-call deadline leaves the standing one in force"

    # `never` clears it, and the connection works again.
    client.renew never
    peer.write [1'u8, 2, 3]
    assert client.read(bytes, afterMs(2000)) == 3 and bytes[2] == 3

    # An expired standing deadline fails a write at once.
    peer.renew afterMs(-1)
    timedOut = false
    try: peer.write [4'u8]
    except ErrorCode as error: timedOut = error == TimeoutError
    assert timedOut
    peer.renew never

    # A ready socket still honours an expired deadline, and the byte waits.
    client.write [5'u8]
    timedOut = false
    try: discard peer.read(bytes, afterMs(-1))
    except ErrorCode as error: timedOut = error == TimeoutError
    assert timedOut
    assert peer.read(bytes, afterMs(2000)) == 1 and bytes[0] == 5
    timedOut = false
    try: client.write([6'u8], afterMs(-1))
    except ErrorCode as error: timedOut = error == TimeoutError
    assert timedOut

    # Ready reads and writes in a loop leave room for another task.
    let shared = Shared()
    assert trySpawnTask(observer(shared))
    for i in 0 ..< 128:
      client.write [7'u8]
      assert peer.read(bytes.toOpenArray(0, 0)) == 1
    assert wait(addr shared.done, afterMs(1000)) == wrReady

    # The deadline argument is evaluated once per operation.
    var calls = 0
    client.write([8'u8, 9], countedDeadline(calls, 2000))
    assert calls == 1
    assert peer.read(bytes, countedDeadline(calls, 2000)) == 2 and calls == 2

    # A write the peer never drains raises at its deadline.
    assert setSendBuffer(client.nativeHandle, 4096)
    assert setRecvBuffer(peer.nativeHandle, 4096)
    let payload = newSeq[byte](16 * 1024 * 1024)
    timedOut = false
    try: client.write(payload, afterMs(30))
    except ErrorCode as error: timedOut = error == TimeoutError
    assert timedOut, "a blocked write reports its deadline"
    close client
    var drain = default(array[65536, byte])
    while peer.read(drain, afterMs(5000)) > 0: discard
    close peer
    close listener
    echo "PASS standing and per-call deadlines, expired ones on ready sockets, a blocked write"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
