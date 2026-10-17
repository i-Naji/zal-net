## Bounded buffered reading over any public byte-stream implementation.
## This module has no dependency on sockets, engines or platform code.
import zal_net/[streamconcepts, buffers, errors]
import zal_net/rt/[time, cancel]
from zal_net/rt import ioCheckpoint, stopping
export streamconcepts, errors
proc cMemchr(p: pointer; c: cint; n: csize_t): pointer {.importc: "memchr", header: "<string.h>".}

# -------------------------------------------------------------- BufReader

type
  BufReader*[S: ByteStream] = object
    ## Buffered reads over any ByteStream. Pass it by pointer
    ## (`addr r`): the procs park. Writes go to the stream directly.
    src*: S
    buf: seq[byte]
    head, tail: int

proc initBufReader*[S: ByteStream](src: S; size = 16 * 1024): BufReader[S] =
  result = BufReader[S](src: src, buf: newSeq[byte](max(size, 64)), head: 0, tail: 0)

proc buffered*[S: ByteStream](r: ptr BufReader[S]): int {.inline.} = r.tail - r.head
  ## Bytes read from the stream and not consumed yet.

proc peek*[S: ByteStream](r: ptr BufReader[S]): ptr UncheckedArray[byte] {.inline.} =
  ## The buffered bytes (`buffered` of them); valid until the next read.
  cast[ptr UncheckedArray[byte]](addr r.buf[r.head])

proc peek*[S: ByteStream](r: BufReader[S]): openArray[byte] {.inline, establishesBorrow.} =
  ## Use the var overloads to keep mutations checked against this borrow.
  r.buf.toOpenArray(r.head, r.tail - 1)

proc consume*[S: ByteStream](r: ptr BufReader[S]; n: int) {.inline.} =
  if n <= 0: return
  r.head = r.head + min(n, r.tail - r.head)
  if r.head == r.tail:
    r.head = 0
    r.tail = 0

proc fill*[S: ByteStream](r: ptr BufReader[S]; deadline = never;
                         tok: nil CancelToken = nil): int {.passive, untyped.} =
  ## One read from the stream after what is buffered: bytes added, 0 end
  ## of stream, <0 an error, TooLong when the buffer is full.
  when not (S is CancellableByteStream):
    if tok != nil: return NotSupported
  retain(tok)
  defer: release(tok)
  ioCheckpoint(0)
  if cancelled(tok) or stopping(): return ECancelled
  if deadline <= monoNow(): return IoTimedOut
  if r.head > 0 and r.tail == r.buf.len:
    let n = r.tail - r.head
    moveMem(addr r.buf[0], addr r.buf[r.head], n)
    r.head = 0
    r.tail = n
  if r.tail == r.buf.len: return TooLong
  when S is CancellableByteStream:
    result = recvInto(r.src, addr r.buf[r.tail], r.buf.len - r.tail, deadline, tok)
  else:
    result = recvInto(r.src, addr r.buf[r.tail], r.buf.len - r.tail, deadline)
  if result > 0: r.tail = r.tail + result

proc find[S: ByteStream](r: ptr BufReader[S]; start: int; delim: string): int =
  ## Offset (from head) just past the first `delim` at or after `start`, or -1.
  result = -1
  let first = cint(ord(delim[0]))
  var i = r.head + start
  while i + delim.len <= r.tail:
    let hit = cMemchr(addr r.buf[i], first, csize_t(r.tail - i))
    if hit == nil: return
    let at = int(cast[uint](hit) - cast[uint](addr r.buf[0]))
    if at + delim.len > r.tail: return
    var k = 1
    while k < delim.len and r.buf[at + k] == byte(delim[k]): k = k + 1
    if k == delim.len: return at + delim.len - r.head
    i = at + 1

proc readUntil*[S: ByteStream](r: ptr BufReader[S]; delim: string; maxLen = 16 * 1024; deadline = never;
                              tok: nil CancelToken = nil): int {.passive.} =
  ## Buffer until `delim` (say "\r\n\r\n" after an HTTP head): the length
  ## up to and including it, left in the buffer (`peek`, then `consume`).
  ## StreamEof, TooLong (not within `maxLen` bytes) or <0 an error.
  if delim.len == 0 or maxLen < 0: return InvalidInput
  when not (S is CancellableByteStream):
    if tok != nil: return NotSupported
  retain(tok)
  defer: release(tok)
  ioCheckpoint(0)
  if cancelled(tok) or stopping(): return ECancelled
  if deadline <= monoNow(): return IoTimedOut
  var scanned = 0
  while true:
    let at = find(r, max(0, scanned - delim.len + 1), delim)
    if at > 0: return (if at <= maxLen: at else: TooLong)
    scanned = r.tail - r.head
    if scanned >= maxLen: return TooLong
    let n = fill(r, deadline, tok)
    if n == 0: return StreamEof
    if n < 0: return n

proc readLine*[S: ByteStream](r: ptr BufReader[S]; line: ptr string; maxLen = 8192; deadline = never;
                             tok: nil CancelToken = nil): int {.passive.} =
  ## The next line without its "\n" (or "\r\n") into `line`: its length,
  ## StreamEof (nothing left), TooLong or <0 an error. A last line without
  ## a newline is returned as a line.
  if maxLen < 0 or maxLen > high(int) - 2: return InvalidInput
  retain(tok)
  defer: release(tok)
  var n = readUntil(r, "\n", maxLen + 2, deadline, tok)
  var take = n
  if n == StreamEof:
    if buffered(r) == 0: return StreamEof
    n = buffered(r)
    take = n
  elif n < 0:
    return n
  else:
    n = n - 1
    if n > 0 and r.buf[r.head + n - 1] == byte('\r'): n = n - 1
  if n > maxLen: return TooLong
  if n > 0:
    copyMem(beginStore(line[], n), addr r.buf[r.head], n)
    endStore(line[])
  else:
    line[].setLen(0)
  consume(r, take)
  result = n

proc recvInto*[S: ByteStream](r: ptr BufReader[S]; p: pointer; n: int; deadline = never;
                             tok: nil CancelToken = nil): int {.passive, untyped.} =
  ## Buffered bytes first; a large read with nothing buffered goes to the
  ## stream directly.
  if n < 0: return InvalidInput
  if n == 0: return 0
  when not (S is CancellableByteStream):
    if tok != nil: return NotSupported
  retain(tok)
  defer: release(tok)
  ioCheckpoint(0)
  if cancelled(tok) or stopping(): return ECancelled
  if deadline <= monoNow(): return IoTimedOut
  if buffered(r) == 0:
    if n >= r.buf.len:
      when S is CancellableByteStream:
        return recvInto(r.src, p, n, deadline, tok)
      else:
        return recvInto(r.src, p, n, deadline)
    let k = fill(r, deadline, tok)
    if k <= 0: return k
  result = min(n, buffered(r))
  copyMem(p, addr r.buf[r.head], result)
  consume(r, result)

proc readExactly*[S: ByteStream](r: ptr BufReader[S]; p: pointer; n: int; deadline = never;
                                tok: nil CancelToken = nil): bool {.passive.} =
  if n < 0: return false
  retain(tok)
  defer: release(tok)
  var off = 0
  let dst = cast[ptr UncheckedArray[byte]](p)
  while off < n:
    let k = recvInto(r, addr dst[off], n - off, deadline, tok)
    if k <= 0: return false
    off = off + k
  result = true

proc sendFrom*[S: ByteStream](r: ptr BufReader[S]; p: pointer; n: int; deadline = never;
                             tok: nil CancelToken = nil): int {.passive, untyped.} =
  ## Straight to the stream: a BufReader is a ByteStream too.
  if n < 0: return InvalidInput
  if n == 0: return 0
  when not (S is CancellableByteStream):
    if tok != nil: return NotSupported
  retain(tok)
  defer: release(tok)
  ioCheckpoint(0)
  if cancelled(tok) or stopping(): return ECancelled
  if deadline <= monoNow(): return IoTimedOut
  when S is CancellableByteStream:
    result = sendFrom(r.src, p, n, deadline, tok)
  else:
    result = sendFrom(r.src, p, n, deadline)

template recvInto*[S: ByteStream](r: ptr BufReader[S]; buf: var openArray[byte];
                                 deadline: Deadline = never; tok: nil CancelToken = nil): int =
  recvInto(r, dataPtr(buf), buf.len, deadline, tok)

template sendFrom*[S: ByteStream](r: ptr BufReader[S]; buf: openArray[byte];
                                 deadline: Deadline = never; tok: nil CancelToken = nil): int =
  sendFrom(r, dataPtr(buf), buf.len, deadline, tok)

template readExactly*[S: ByteStream](r: ptr BufReader[S]; buf: var openArray[byte];
                                    deadline: Deadline = never; tok: nil CancelToken = nil): bool =
  readExactly(r, dataPtr(buf), buf.len, deadline, tok)

proc consume*[S: ByteStream](r: var BufReader[S]; n: int) {.inline.} =
  consume(addr r, n)

proc fill*[S: ByteStream](r: var BufReader[S]; deadline = never;
                         tok: nil CancelToken = nil): int {.passive.} =
  fill(addr r, deadline, tok)

from zal_net/io import IoResult
proc readExactly*[S: ByteStream](r: var BufReader[S]; buffer: var openArray[byte];
                                deadline = never; tok: nil CancelToken = nil): IoResult {.passive.} =
  ## Preserve partial progress on EOF, cancellation and I/O failure.
  result = default(IoResult)
  retain(tok)
  defer: release(tok)
  while result.bytes < buffer.len:
    let count = recvInto(addr r, addr buffer[result.bytes], buffer.len - result.bytes, deadline, tok)
    if count <= 0:
      result.error = if count == 0: StreamEof else: count
      return
    result.bytes += count
