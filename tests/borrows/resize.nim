import zal_net/buffers
import std/assertions
var bytes = @[1'u8, 2, 3]
let borrowed = view(bytes)
bytes.add 4
assert borrowed.len == 3
