## Byte helpers for protocol code: big-endian integers over open arrays and
## raw pointers, and a comparison whose time does not depend on the data.

proc u16be*(buf: openArray[byte]; i: int): uint16 {.inline.} =
  result = (uint16(buf[i]) shl 8) or uint16(buf[i + 1])

proc u64be*(buf: openArray[byte]; i: int): uint64 =
  result = 0
  var k = 0
  while k < 8:
    result = (result shl 8) or uint64(buf[i + k])
    k = k + 1

proc putU16be*(buf: var openArray[byte]; i: int; n: uint16) {.inline.} =
  buf[i] = byte(n shr 8)
  buf[i + 1] = byte(n and 0xff)

proc putU64be*(buf: var openArray[byte]; i: int; n: uint64) =
  var x = n
  var k = 7
  while k >= 0:
    buf[i + k] = byte(x and 0xff)
    x = x shr 8
    k = k - 1

proc beU16*(p: ptr UncheckedArray[byte]; i: int): uint16 {.inline.} =
  result = (uint16(p[i]) shl 8) or uint16(p[i + 1])

proc beU64*(p: ptr UncheckedArray[byte]; i: int): uint64 {.inline.} =
  result = 0
  var k = 0
  while k < 8:
    result = (result shl 8) or uint64(p[i + k])
    k = k + 1

proc putBeU16*(p: ptr UncheckedArray[byte]; i: int; v: uint16) {.inline.} =
  p[i] = byte(v shr 8)
  p[i + 1] = byte(v and 0xff)

proc putBeU64*(p: ptr UncheckedArray[byte]; i: int; v: uint64) {.inline.} =
  var x = v
  var k = 7
  while k >= 0:
    p[i + k] = byte(x and 0xff)
    x = x shr 8
    k = k - 1

proc sameBytes*(a, b: pointer; n: int): bool =
  ## Equal, compared in time that depends only on `n` (secrets, tokens).
  let x = cast[ptr UncheckedArray[byte]](a)
  let y = cast[ptr UncheckedArray[byte]](b)
  var acc = 0'u8
  var i = 0
  while i < n:
    acc = acc or (x[i] xor y[i])
    i = i + 1
  result = acc == 0

proc b64Val(c: char): int {.inline.} =
  if c >= 'A' and c <= 'Z': ord(c) - ord('A')
  elif c >= 'a' and c <= 'z': ord(c) - ord('a') + 26
  elif c >= '0' and c <= '9': ord(c) - ord('0') + 52
  elif c == '+' or c == '-': 62
  elif c == '/' or c == '_': 63
  else: -1

proc b64DecodeStrict*(s: openArray[char]; outp: var seq[byte]): bool =
  ## Standard or URL-safe base64, padded or not. Any other character, or a
  ## misplaced '=', fails (std/base64 skips junk silently).
  outp.setLen(0)
  var n = s.len
  while n > 0 and s[n - 1] == '=': n = n - 1
  if s.len - n > 2 or n mod 4 == 1: return false
  var acc = 0
  var bits = 0
  var i = 0
  while i < n:
    let v = b64Val(s[i])
    if v < 0: return false
    acc = (acc shl 6) or v
    bits = bits + 6
    if bits >= 8:
      bits = bits - 8
      outp.add byte((acc shr bits) and 0xff)
    i = i + 1
  # Leftover bits must be zero (canonical encoding).
  result = (acc and ((1 shl bits) - 1)) == 0
