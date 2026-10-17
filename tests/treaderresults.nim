import std/[assertions, syncio]
import zal_net/[rt, reader, errors]

type Source = object
  calls, ending: int
proc recvInto(s: ptr Source; p: pointer; n: int; deadline: Deadline): int {.passive.} =
  inc s.calls
  if s.calls > 1: return s.ending
  let bytes = cast[ptr UncheckedArray[byte]](p)
  result = min(n, 2)
  for i in 0..<result: bytes[i] = byte(i + 1)
proc sendFrom(s: ptr Source; p: pointer; n: int; deadline: Deadline): int {.passive.} = n

proc main() {.passive.} =
  for ending in [0, IoTimedOut, ECancelled]:
    var source = Source(ending: ending)
    var bufferedSource = initBufReader(addr source)
    block:
      let empty = peek(bufferedSource)
      assert empty.len == 0
    var bytes = default(array[4, byte])
    let outcome = readExactly(bufferedSource, bytes)
    assert outcome.bytes == 2
    assert outcome.error == (if ending == 0: StreamEof else: ending)
    assert bytes[0] == 1 and bytes[1] == 2
  echo "PASS exact reads preserve partial progress"
assert runMain(main())
