## readLine over line lengths around buffer boundaries, with LF, CRLF and no
## line end at all, a NUL inside the line, and the end of the stream after it.
import std/[assertions, syncio]
import zal_net/rt
import zal_net/conn

proc pattern(n: int): string =
  result = newString(n)
  for i in 0 ..< n: result[i] = char(ord('a') + i mod 26)
  if n > 1: result[1] = '\0'

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
    close listener
    echo "PASS readLine across lengths, LF, CRLF, no line end, a NUL and the end"
  except ErrorCode as error:
    echo "unexpected error ", error
    assert false

assert runMain(main())
