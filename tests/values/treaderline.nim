import std/[assertions, syncio]
import zal_net/[rt, reader]

type Source = object
  data: string
  offset, fragment: int

proc recvInto(s: ptr Source; p: pointer; n: int; deadline: Deadline): int {.passive.} =
  result = min(min(n, s.fragment), s.data.len - s.offset)
  if result > 0:
    let data = cast[ptr UncheckedArray[char]](s.data.toCString)
    copyMem(p, addr data[s.offset], result)
    s.offset += result
proc sendFrom(s: ptr Source; p: pointer; n: int; deadline: Deadline): int {.passive.} = n

proc pattern(n: int): string =
  result = newString(n)
  for i in 0..<n: result[i] = char(ord('a') + i mod 26)
  if n > 1: result[1] = '\0'

proc main() {.passive.} =
  when defined(readerLineBench):
    const Rounds = 8192
    for size in [32, 1024, 8190]:
      let expected = pattern(size)
      var data = ""
      for i in 0..<Rounds: data.add expected & "\n"
      for run in 0..<5:
        var source = Source(data: data, fragment: 65536)
        var reader = initBufReader(addr source)
        var line = ""
        let started = monoNow()
        for i in 0..<Rounds:
          assert readLine(addr reader, addr line) == size
        let elapsed = int64(monoNow()) - int64(started)
        assert line == expected
        echo "line_bytes=", size, " rounds=", Rounds, " elapsed_ns=", elapsed
  else:
    var line = pattern(8190)
    for size in [0, 1, 7, 15, 16, 23, 24, 31, 32, 63, 64, 255, 8190]:
      let expected = pattern(size)
      for ending in ["\n", "\r\n", ""]:
        var source = Source(data: expected & ending, fragment: 7)
        var reader = initBufReader(addr source)
        let previous = line
        var saved = newSeq[byte](line.len)
        for i in 0..<line.len: saved[i] = byte(line[i])
        let count = readLine(addr reader, addr line)
        if source.data.len == 0:
          assert count == StreamEof
          assert line == previous
        else:
          assert count == size and line == expected
          assert readLine(addr reader, addr line) == StreamEof
        assert previous.len == saved.len
        for i in 0..<saved.len: assert byte(previous[i]) == saved[i]
    echo "PASS reader lines: string boundaries, shared output, CRLF, NUL and EOF"

assert runMain(main())
