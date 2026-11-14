## Byte helpers: big-endian round trips, constant-time comparison, strict
## base64 (standard, URL-safe, unpadded; junk and non-canonical tails refused).
import std/assertions
import std/syncio
import zal_net/bytes

proc main() =
  var b = default(array[16, byte])
  putU16be(b, 0, 0xBEEF'u16)
  putU64be(b, 2, 0x0102030405060708'u64)
  assert u16be(b, 0) == 0xBEEF'u16 and u64be(b, 2) == 0x0102030405060708'u64
  putBeU16(cast[ptr UncheckedArray[byte]](addr b[0]), 10, 7'u16)
  assert beU16(cast[ptr UncheckedArray[byte]](addr b[0]), 10) == 7'u16
  assert beU64(cast[ptr UncheckedArray[byte]](addr b[0]), 2) == 0x0102030405060708'u64
  var x = [1'u8, 2, 3]
  var y = [1'u8, 2, 3]
  assert sameBytes(addr x[0], addr y[0], 3)
  y[2] = 4
  assert not sameBytes(addr x[0], addr y[0], 3)
  var o: seq[byte] = @[]
  assert b64DecodeStrict("AAECAw==", o) and o == @[0'u8, 1, 2, 3]
  assert b64DecodeStrict("AAECAw", o) and o == @[0'u8, 1, 2, 3]
  assert b64DecodeStrict("-_8", o) and o == @[0xfb'u8, 0xff]
  assert not b64DecodeStrict("AA=C", o)
  assert not b64DecodeStrict("AB", o)            # non-zero leftover bits
  assert not b64DecodeStrict("A", o)
  echo "PASS big-endian helpers, sameBytes, strict base64"

main()
