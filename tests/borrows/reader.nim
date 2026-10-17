import zal_net/reader
import std/assertions
type Source = object
proc recvInto(s: Source; p: pointer; n: int; d: Deadline): int {.passive.} = 0
proc sendFrom(s: Source; p: pointer; n: int; d: Deadline): int {.passive.} = 0
var bufferedSource = initBufReader(Source())
let bytes = peek(bufferedSource)
consume(bufferedSource, 1)
assert bytes.len == 0
