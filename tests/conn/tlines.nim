## readLine over line lengths around buffer boundaries, with LF, CRLF and no
## line end at all, a NUL inside the line, and the end of the stream after it.
## Then a mixed stream: lines, an empty line, a head found with peek, an
## exact body, a last line without its end; an expired fill keeps what is
## buffered, and a line longer than MaxBuffered raises FullError.
import std/[assertions, syncio]
import zal_net/rt
import zal_net/conn

proc pattern(n: int): string =
  result = newString(n)
  for i in 0 ..< n: result[i] = char(ord('a') + i mod 26)
  if n > 1: result[1] = '\0'

proc headLength(bytes: openArray[byte]): int =
  result = -1
  for i in 3 ..< bytes.len:
    if bytes[i-3] == 13 and bytes[i-2] == 10 and bytes[i-1] == 13 and bytes[i] == 10:
      return i + 1

proc mixed(listener: var Listener) {.passive, raises.} =
  var c = connect("127.0.0.1", listener.port, afterMs(2000))
  var peer = accept(listener, afterMs(2000))
  c.renew afterMs(5000)
  peer.write "first\r\nsecond\n\r\nHEAD: x\r\n\r\nbody12345" & "0123456789abcdef" & "\nlast"
  peer.shutdownWrite()
  assert c.readLine() == "first"
  let pending = c.buffered
  var timedOut = false
  try: discard c.fill(afterMs(-1))
  except ErrorCode as error: timedOut = error == TimeoutError
  assert timedOut and c.buffered == pending, "an expired fill keeps the buffer"
  assert c.readLine() == "second"
  assert c.readLine() == "" and c.buffered > 0, "an empty line"
  var size = headLength(c.peek)
  while size < 0:
    assert c.fill() > 0
    size = headLength(c.peek)
  assert size == 11 and c.peek[0] == byte('H')
  c.consume size
  var body = default(array[25, byte])
  var got = 0
  while got < body.len: got += c.read(body.toOpenArray(got, body.len - 1))
  assert body[0] == byte('b') and body[24] == byte('f')
  assert c.readLine() == "", "the line end after the body"
  assert c.readLine() == "last"
  assert c.readLine() == "" and c.buffered == 0 and c.fill() == 0

  var long = connect("127.0.0.1", listener.port, afterMs(2000))
  var writer = accept(listener, afterMs(2000))
  long.renew afterMs(5000)
  writer.renew afterMs(5000)
  writer.write newSeq[byte](MaxBuffered + 1)
  var full = false
  try: discard long.readLine()
  except ErrorCode as error: full = error == FullError
  assert full, "a line longer than MaxBuffered"

proc main() {.passive.} =
  try:
    var listener = listen(0, "127.0.0.1")
    for size in [0, 1, 7, 15, 16, 23, 24, 31, 32, 63, 64, 255, 8190]:
      let expected = pattern(size)
      for ending in ["\n", "\r\n", ""]:
        var c = connect("127.0.0.1", listener.port, afterMs(2000))
        var peer = accept(listener, afterMs(2000))
        c.renew afterMs(5000)
        let data = expected & ending
        var at = 0
        while at < data.len:
          # Seven bytes at a time, so a line can arrive in pieces.
          let piece = data.substr(at, min(at + 7, data.len) - 1)
          peer.write piece
          at += piece.len
          yieldNow()
        peer.shutdownWrite()
        let line = c.readLine()
        assert line == expected, "size " & $size & " ending " & $ending.len
        assert c.readLine() == "" and c.buffered == 0, "the end follows the line"
    mixed(listener)
    close listener
    echo "PASS readLine across lengths and line ends, a mixed stream, an expired fill, a line too long"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
