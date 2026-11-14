import std/[assertions, syncio]
import zal_net/rt
import zal_net/rt/sync
import zal_net/conn

type Shared = ref object
  done: Event
  served: int

proc spell(frame: var openArray[byte]) =
  frame[0] = 1; frame[1] = 2; frame[2] = 3

proc serve(listener: ptr Listener; shared: Shared) {.passive.} =
  try:
    var c = accept(listener[], afterMs(5000))
    c.renew afterMs(5000)
    var buffer = default(array[4096, byte])
    while true:
      let count = c.read(buffer)
      if count == 0: break
      c.write buffer.toOpenArray(0, count - 1)
      inc shared.served
  except ErrorCode as error:
    echo "server: ", error
  setEvent(addr shared.done)

proc main() {.passive.} =
  try:
    var listener = listen(0, "127.0.0.1")
    let shared = Shared()
    assert trySpawnTask(serve(addr listener, shared))
    var c = connect("127.0.0.1", listener.port, afterMs(5000))
    c.renew afterMs(5000)

    c.write "hello\r\nworld\n"
    assert c.readLine() == "hello"
    assert c.readLine() == "world"

    # peek/consume: a parser sees the bytes without taking them.
    c.write "abcdef"
    while c.buffered < 6: assert c.fill() > 0
    assert c.peek.len == 6 and c.peek[0] == byte('a')
    c.consume 2
    var four = default(array[4, byte])
    assert c.read(four) == 4 and four[0] == byte('c') and four[3] == byte('f')

    # scratch/flush: one staged write.
    spell c.scratch(3)
    c.flush 3
    var three = default(array[3, byte])
    var got = 0
    while got < 3: got += c.read(three.toOpenArray(got, 2))
    assert three == [1'u8, 2, 3]

    # A deadline that passes raises; the connection stays usable.
    var timedOut = false
    try: discard c.fill(afterMs(30))
    except ErrorCode as error: timedOut = error == TimeoutError
    assert timedOut
    c.write "x"
    assert c.fill() == 1

    c.shutdownWrite()
    assert wait(addr shared.done, afterMs(5000)) == wrReady
    assert shared.served >= 4
    c.consume c.buffered
    assert c.fill() == 0
    close c
    close listener
    echo "PASS connect, lines, peek/consume, scratch/flush, a timeout and the half-close"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
