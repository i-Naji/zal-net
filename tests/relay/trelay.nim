{.feature: "assumeSync".}
## The relay with toy framers: records of [length:2][zero pad][payload XOR
## 0x5A][tail bytes, each the length's low byte], in two geometries: 18/16
## with 65535-byte records (Shadowsocks 2022's), and 4/4 with 4096-byte
## records. Covers framed <-> plain both ways with half-close, a burst of
## more records than spans per batch, plain <-> plain, a plain source laid
## out for a small-record sink, same-geometry re-sealing, refused framer
## pairs, the hooks and end reasons, the idle timeout, and that every block
## goes back.
import std/assertions
import std/syncio
import std/atomics
import zal_net/rt
import zal_net/raw/io
import zal_net/raw/socket
import zal_net/bytes
import zal_net/relay
import zal_net/raw/tcp, zal_net/net/address

const Key = 0x5A'u8

# ------------------------------------------------------------ toy framers

proc toyOpen(c: Conn; d: DirectionPtr): int =
  let f = d.srcFramer
  if f == nil: return InFail
  let g = f.geometry
  d.nspans = 0
  d.bytes = 0
  while d.nspans < MaxSpans:
    let avail = d.fill - d.off
    if avail < g.head: break
    let n = int(beU16(d.buf, d.off))
    if n > g.maxRecord: return InFail
    if avail < g.head + n + g.tail: break
    var k = 0
    while k < g.head - 2:
      if d.buf[d.off + 2 + k] != 0: return InFail
      k = k + 1
    let p = d.off + g.head
    k = 0
    while k < g.tail:
      if d.buf[p + n + k] != byte(n and 0xff): return InFail
      k = k + 1
    k = 0
    while k < n:
      d.buf[p + k] = d.buf[p + k] xor Key
      k = k + 1
    if n > 0:
      d.spans[d.nspans] = Span(off: p, len: n)
      d.nspans = d.nspans + 1
      d.bytes = d.bytes + n
    d.off = p + n + g.tail
  result = d.nspans

proc toyBoundary(d: DirectionPtr): bool = true

proc toySeal(c: Conn; d: DirectionPtr): bool =
  let f = d.dstFramer
  if f == nil: return false
  let g = f.geometry
  var i = 0
  while i < d.nspans:
    let off = d.spans[i].off
    let n = d.spans[i].len
    let start = off - g.head
    if n > g.maxRecord or start < 0 or (i > 0 and start != d.wEnd): return false
    putBeU16(d.buf, start, uint16(n))
    zeroMem(bufAt(d, start + 2), g.head - 2)
    var k = 0
    while k < n:
      d.buf[off + k] = d.buf[off + k] xor Key
      k = k + 1
    k = 0
    while k < g.tail:
      d.buf[off + n + k] = byte(n and 0xff)
      k = k + 1
    if i == 0: d.wOff = start
    d.wEnd = off + n + g.tail
    i = i + 1
  result = true

proc noClose(d: DirectionPtr) = discard

proc toyFramer(head, tail, maxRecord, headRoom: int): FramerObj =
  FramerObj(geometry: Geometry(head: head, tail: tail, maxRecord: maxRecord, headRoom: headRoom),
            open: toyOpen, atBoundary: toyBoundary, seal: toySeal,
            closeSource: noClose, closeSink: noClose)

proc putEmpty(d: DirectionPtr) =
  ## An empty 4/4 toy record into the control prefix.
  zeroMem(addr d.pre[0], 8)
  d.preLen = 8
  d.preAt = 0

proc markSeal(c: Conn; d: DirectionPtr): bool =
  ## toySeal, and an empty record before the first batch (the prefix).
  result = toySeal(c, d)
  if result and sinkState[array[StateWords, uint64]](d)[][0] == 0:
    sinkState[array[StateWords, uint64]](d)[][0] = 1
    putEmpty(d)

proc markFinish(c: Conn; d: DirectionPtr): bool =
  ## An empty record at the clean end of stream, before the half-close.
  putEmpty(d)
  result = true

var gFrame = toyFramer(18, 16, MaxRecord, 0)       # Shadowsocks 2022's geometry
var gSmall = toyFramer(4, 4, 4096, 0)
var gWide = toyFramer(4, 4, 4096, HeadRoom + 72)   # asks for more room than the relay has
var gTallHead = toyFramer(HeadRoom + 2, 4, 4096, 0) # a head alone beyond HeadRoom
var gHugeTail = toyFramer(4, 300_000, 4096, 0)      # no record fits a direction's buffer
var gPrefixCalls: int            # writePrefix calls (the hook is re-entered)
var gReadFailed: int              # readFailed calls

proc slowPrefix(c: Conn; d: DirectionPtr): int =
  ## The sink writes its own prefix, three bytes a call: InAgain until done.
  gPrefixCalls = gPrefixCalls + 1
  let n = min(3, d.preLen - d.preAt)
  let k = writeSome(d.dst, addr d.pre[d.preAt], n)
  if k > 0: d.preAt = d.preAt + k
  elif k != IoAgain: return InFail
  result = if d.preAt < d.preLen: InAgain else: 1

proc endOnReset(c: Conn; d: DirectionPtr; err: int): int =
  ## A failed read after whole records is a clean end here.
  gReadFailed = gReadFailed + 1
  if err == 0: return InFail                     # the read's error is passed along
  result = if d.off == d.fill: InEof else: InFail

const StateMark = 0xABCD'u64
var gCloseSinkOk: int             # closeSink calls that saw their own state (StateMark)
var gCloseSinkBad: int

proc checkCloseSink(d: DirectionPtr) =
  ## A sink's close hook must be handed the Dir that holds its state.
  if sinkState[array[StateWords, uint64]](d)[][1] == StateMark: gCloseSinkOk = gCloseSinkOk + 1
  else: gCloseSinkBad = gCloseSinkBad + 1
  sinkState[array[StateWords, uint64]](d)[][1] = 0

var gCheckedSink = FramerObj(geometry: Geometry(head: 4, tail: 4, maxRecord: 4096, headRoom: 0),
                             open: toyOpen, atBoundary: toyBoundary, seal: toySeal,
                             closeSource: noClose, closeSink: checkCloseSink)
var gSelfPrefix = FramerObj(geometry: Geometry(head: 4, tail: 4, maxRecord: 4096, headRoom: 0),
                            open: toyOpen, atBoundary: toyBoundary, seal: markSeal, finish: markFinish,
                            writePrefix: slowPrefix, closeSource: noClose, closeSink: noClose)
var gEndOnReset = FramerObj(geometry: Geometry(head: 4, tail: 4, maxRecord: 4096, headRoom: 0),
                            open: toyOpen, atBoundary: toyBoundary, seal: toySeal,
                            readFailed: endOnReset, closeSource: noClose, closeSink: noClose)
var gMark = FramerObj(geometry: Geometry(head: 4, tail: 4, maxRecord: 4096, headRoom: 0),
                      open: toyOpen, atBoundary: toyBoundary, seal: markSeal, finish: markFinish,
                      closeSource: noClose, closeSink: noClose)   # 4/4 with prefix and finish records
var gZero = FramerObj(geometry: Geometry(), open: toyOpen, atBoundary: toyBoundary, seal: toySeal,
                      closeSource: noClose, closeSink: noClose)   # geometry left out

# ------------------------------------------------------------------ hooks

var gBatchUp, gBatchDown: int   # atomic: bytes onBatch saw per direction
var gEnds: int                  # atomic: onEnd calls
var gEndReason: int             # the last onEnd's reason (ord)
var gEndUp, gEndDown: int64     # the connection's counters at onEnd

proc hookBatch(c: Conn; d: DirectionPtr; bytes: int) =
  if d == addr c.a: discard atomicFetchAdd(gBatchUp, bytes, moRelaxed)
  else: discard atomicFetchAdd(gBatchDown, bytes, moRelaxed)

proc hookEnd(c: Conn) =
  gEndReason = ord(c.endReason)
  gEndUp = c.upBytes
  gEndDown = c.downBytes
  discard atomicFetchAdd(gEnds, 1, moAcquireRelease)

var gHooks = ConnHooks(onBatch: hookBatch, onEnd: hookEnd)

proc resetHooks() =
  atomicStore(gBatchUp, 0, moRelaxed)
  atomicStore(gBatchDown, 0, moRelaxed)
  atomicStore(gEnds, 0, moRelease)
  gEndReason = -1

# ------------------------------------------------------------ test side

proc pat(i, seed: int): byte {.inline.} = byte((i * 131 + seed) and 0xff)

var gOk: int      # atomic: checks passed
var gBad: int     # atomic: checks failed

proc pass() = discard atomicFetchAdd(gOk, 1, moAcquireRelease)
proc fail(why: string) =
  echo "FAIL ", why
  discard atomicFetchAdd(gBad, 1, moAcquireRelease)

proc writePlain(fd: cint; total, seed: int; halfClose: bool) {.passive.} =
  var buf = default(array[8192, byte])
  var sent = 0
  while sent < total:
    let n = min(buf.len, total - sent)
    var k = 0
    while k < n:
      buf[k] = pat(sent + k, seed)
      k = k + 1
    if not writeAll(fd, addr buf[0], n, 5000): fail("writePlain")
    sent = sent + n
  if halfClose: shutdownWrite(fd)

proc writePlainFrom(fd: cint; start, total, seed: int; halfClose: bool) {.passive.} =
  ## The pattern's bytes start ..< start + total.
  var buf = default(array[8192, byte])
  var sent = 0
  while sent < total:
    let n = min(buf.len, total - sent)
    var k = 0
    while k < n:
      buf[k] = pat(start + sent + k, seed)
      k = k + 1
    if not writeAll(fd, addr buf[0], n, 5000): fail("writePlainFrom")
    sent = sent + n
  if halfClose: shutdownWrite(fd)

proc writeFramed(fd: cint; total, seed, chunk, head, tail: int; halfClose: bool) {.passive.} =
  ## `total` payload bytes in records of `chunk` bytes, several per write.
  var buf = default(array[65536, byte])
  var sent = 0
  var fill = 0
  while sent < total:
    let n = min(chunk, total - sent)
    if fill + head + n + tail > buf.len:
      if not writeAll(fd, addr buf[0], fill, 5000): fail("writeFramed")
      fill = 0
    putU16be(buf, fill, uint16(n))
    zeroMem(addr buf[fill + 2], head - 2)
    var k = 0
    while k < n:
      buf[fill + head + k] = pat(sent + k, seed) xor Key
      k = k + 1
    k = 0
    while k < tail:
      buf[fill + head + n + k] = byte(n and 0xff)
      k = k + 1
    fill = fill + head + n + tail
    sent = sent + n
  if fill > 0 and not writeAll(fd, addr buf[0], fill, 5000): fail("writeFramed")
  if halfClose: shutdownWrite(fd)

proc readPlain(fd: cint; total, seed: int; label: string) {.passive.} =
  var buf = default(array[16384, byte])
  var got = 0
  while true:
    let n = waitRead(fd, addr buf[0], buf.len, 5000)
    if n <= 0: break
    var k = 0
    while k < n:
      if buf[k] != pat(got + k, seed):
        fail(label & ": byte " & $(got + k))
        return
      k = k + 1
    got = got + n
  if got == total: pass()
  else: fail(label & ": got " & $got & " of " & $total)

var gEmpties: int        # readFramed: empty records seen ...
var gFirstEmpty: bool    # ... whether the first record was one ...
var gLastEmpty: bool     # ... and the last

proc readFramed(fd: cint; total, seed, head, tail, maxRecord: int; label: string) {.passive.} =
  var buf = default(array[200000, byte])
  var fill = 0
  var got = 0
  var records = 0
  gEmpties = 0
  gFirstEmpty = false
  gLastEmpty = false
  var eof = false
  while not eof:
    let n = waitRead(fd, addr buf[fill], buf.len - fill, 5000)
    if n <= 0: eof = true
    else: fill = fill + n
    var off = 0
    while fill - off >= head:
      let ln = int(u16be(buf, off))
      if ln > maxRecord:
        fail(label & ": record of " & $ln & " bytes")
        return
      if fill - off < head + ln + tail: break
      var k = 0
      while k < ln:
        if (buf[off + head + k] xor Key) != pat(got + k, seed):
          fail(label & ": byte " & $(got + k))
          return
        k = k + 1
      k = 0
      while k < tail:
        if buf[off + head + ln + k] != byte(ln and 0xff):
          fail(label & ": trailer")
          return
        k = k + 1
      if ln == 0:
        gEmpties = gEmpties + 1
        if records == 0: gFirstEmpty = true
      gLastEmpty = ln == 0
      records = records + 1
      got = got + ln
      off = off + head + ln + tail
    if off > 0:
      moveMem(addr buf[0], addr buf[off], fill - off)
      fill = fill - off
  if got == total and fill == 0: pass()
  else: fail(label & ": got " & $got & " of " & $total & ", " & $fill & " left over")

proc runRelay(c: Conn) {.passive.} =
  startPumps(c)

proc makeConn(timeoutMs: int; aSrc, aDst, bSrc, bDst: nil Framer;
              outer, outerUp: var cint): Conn =
  ## outer <-> [fd | relay | up] <-> outerUp; direction a runs fd -> up.
  let (o1, r1) = openPair()
  let (r2, o2) = openPair()
  let c = newConn(timeoutMs)
  if c == nil: quit "trelay: no connection block"
  result = c
  result.fd = r1
  result.up = r2
  result.a.src = r1
  result.a.dst = r2
  result.a.srcFramer = aSrc
  result.a.dstFramer = aDst
  result.b.src = r2
  result.b.dst = r1
  result.b.srcFramer = bSrc
  result.b.dstFramer = bDst
  outer = o1
  outerUp = o2

proc readToEnd(fd: cint; ending: ptr int) {.passive.} =
  ## Read until the end; `ending` is how it ended: 0 FIN, <0 an error (a reset).
  var buf = default(array[16384, byte])
  while true:
    let n = waitRead(fd, addr buf[0], buf.len, 5000)
    if n <= 0:
      ending[] = n
      break
  pass()

proc readCounting(fd: cint; ending: ptr int; count: ptr int) {.passive.} =
  ## readToEnd, counting the bytes before the end.
  var buf = default(array[16384, byte])
  while true:
    let n = waitRead(fd, addr buf[0], buf.len, 5000)
    if n <= 0:
      ending[] = n
      break
    count[] = count[] + n
  pass()

proc tcpPair(outer, inner: var cint) {.passive.} =
  ## A loopback TCP connection (a reset is visible there; not in a socketpair).
  var l = listenTcp(0, "127.0.0.1")
  var cl = connect(initSocketAddress(loopback4(), port(l)))
  var sv = accept(l)
  outer = takeNativeHandle(addr cl)
  inner = takeNativeHandle(addr sv)
  closeNow(l)

proc waitChecks(n: int) {.passive.} =
  var spins = 0
  while atomicLoad(gOk, moAcquire) + atomicLoad(gBad, moAcquire) < n and spins < 10_000:
    sleepMs(1)
    spins = spins + 1

proc waitEnds(n: int) {.passive.} =
  var spins = 0
  while atomicLoad(gEnds, moAcquire) < n and spins < 10_000:
    sleepMs(1)
    spins = spins + 1

proc expectRefused(aSrc, aDst: nil Framer; label: string) {.passive.} =
  ## The pair cannot be laid out: the connection ends once, as rejected,
  ## and both peers see their socket close.
  var o1: cint = -1
  var o2: cint = -1
  resetHooks()
  let c = makeConn(5000, aSrc, aDst, nil, nil, o1, o2)
  c.hooks = addr gHooks
  spawnTask runRelay(c)
  var b = 0'u8
  assert waitRead(o1, addr b, 1, 2000) <= 0
  assert waitRead(o2, addr b, 1, 2000) <= 0
  waitEnds(1)
  assert atomicLoad(gEnds, moAcquire) == 1 and gEndReason == ord(erRejected)
  closeFd(o1)
  closeFd(o2)
  echo "PASS refused: ", label

proc main() {.passive.} =
  let base = liveConnections()
  var o1: cint = -1
  var o2: cint = -1

  # plain -> framer and framer -> plain at once, 2 MiB each, half-closed.
  let c = makeConn(5000, nil, addr gFrame, addr gFrame, nil, o1, o2)
  spawnTask runRelay(c)
  spawnTask writePlain(o1, 2 shl 20, 7, true)
  spawnTask readFramed(o2, 2 shl 20, 7, 18, 16, MaxRecord, "plain->framer")
  spawnTask writeFramed(o2, 2 shl 20, 11, 60_000, 18, 16, true)
  spawnTask readPlain(o1, 2 shl 20, 11, "framer->plain")
  waitChecks(2)
  assert atomicLoad(gBad, moAcquire) == 0
  closeFd(o1)
  closeFd(o2)
  echo "PASS framer <-> plain, 2 MiB each way, half-close"

  # 200 tiny records in a burst: more than MaxSpans per batch.
  let c2 = makeConn(5000, nil, nil, addr gFrame, nil, o1, o2)
  spawnTask runRelay(c2)
  spawnTask writeFramed(o2, 2000, 3, 10, 18, 16, true)
  spawnTask readPlain(o1, 2000, 3, "burst")
  shutdownWrite(o1)
  waitChecks(3)
  assert atomicLoad(gBad, moAcquire) == 0
  closeFd(o1)
  closeFd(o2)
  echo "PASS 200-record burst"

  # plain <-> plain, 1 MiB each way.
  let c3 = makeConn(5000, nil, nil, nil, nil, o1, o2)
  spawnTask runRelay(c3)
  spawnTask writePlain(o1, 1 shl 20, 5, true)
  spawnTask readPlain(o2, 1 shl 20, 5, "plain a")
  spawnTask writePlain(o2, 1 shl 20, 9, true)
  spawnTask readPlain(o1, 1 shl 20, 9, "plain b")
  waitChecks(5)
  assert atomicLoad(gBad, moAcquire) == 0
  closeFd(o1)
  closeFd(o2)
  echo "PASS plain <-> plain, 1 MiB each way"

  # A plain source laid out for a small-record sink, and back: 2 MiB each way.
  let c5 = makeConn(5000, nil, addr gSmall, addr gSmall, nil, o1, o2)
  spawnTask runRelay(c5)
  spawnTask writePlain(o1, 2 shl 20, 13, true)
  spawnTask readFramed(o2, 2 shl 20, 13, 4, 4, 4096, "plain->small")
  spawnTask writeFramed(o2, 2 shl 20, 17, 4000, 4, 4, true)
  spawnTask readPlain(o1, 2 shl 20, 17, "small->plain")
  waitChecks(7)
  assert atomicLoad(gBad, moAcquire) == 0
  closeFd(o1)
  closeFd(o2)
  echo "PASS plain <-> 4/4/4096 framer, 2 MiB each way"

  # The same geometry on both sides: records re-sealed in place, 1 MiB.
  let c6 = makeConn(5000, addr gSmall, addr gSmall, nil, nil, o1, o2)
  spawnTask runRelay(c6)
  spawnTask writeFramed(o1, 1 shl 20, 19, 3000, 4, 4, true)
  spawnTask readFramed(o2, 1 shl 20, 19, 4, 4, 4096, "small->small")
  shutdownWrite(o2)
  waitChecks(8)
  assert atomicLoad(gBad, moAcquire) == 0
  closeFd(o1)
  closeFd(o2)
  echo "PASS 4/4 framer -> 4/4 framer, 1 MiB"

  # A sink's control prefix and end-of-stream record: an empty record
  # before the first batch, another before the half-close; plain and framed
  # sources.
  for framedSrc in [false, true]:
    let cm = if framedSrc: makeConn(5000, addr gSmall, addr gMark, nil, nil, o1, o2)
             else: makeConn(5000, nil, addr gMark, nil, nil, o1, o2)
    spawnTask runRelay(cm)
    if framedSrc: spawnTask writeFramed(o1, 1 shl 20, 31, 3000, 4, 4, true)
    else: spawnTask writePlain(o1, 1 shl 20, 31, true)
    let before = atomicLoad(gOk, moAcquire) + atomicLoad(gBad, moAcquire)
    spawnTask readFramed(o2, 1 shl 20, 31, 4, 4, 4096, "prefix and finish")
    shutdownWrite(o2)
    waitChecks(before + 1)
    assert atomicLoad(gBad, moAcquire) == 0
    assert gEmpties == 2 and gFirstEmpty and gLastEmpty, $gEmpties
    closeFd(o1)
    closeFd(o2)
  echo "PASS a sink's prefix record before the first batch and its finish record before FIN"

  # A sink that writes its own prefix (a kTLS control record), re-entered
  # until done; a source whose failed read after whole records is a clean end.
  gPrefixCalls = 0
  let cp = makeConn(5000, nil, addr gSelfPrefix, nil, nil, o1, o2)
  spawnTask runRelay(cp)
  spawnTask writePlain(o1, 1 shl 20, 47, true)
  let bp = atomicLoad(gOk, moAcquire) + atomicLoad(gBad, moAcquire)
  spawnTask readFramed(o2, 1 shl 20, 47, 4, 4, 4096, "self-written prefix")
  shutdownWrite(o2)
  waitChecks(bp + 1)
  assert atomicLoad(gBad, moAcquire) == 0
  assert gEmpties == 2 and gFirstEmpty and gLastEmpty and gPrefixCalls >= 6, $gPrefixCalls
  closeFd(o1)
  closeFd(o2)
  # A read that fails at once (a listening socket as the source): the hook
  # makes it a clean end, which the other side sees as FIN.
  gReadFailed = 0
  let lr = tryListenTcp(0, 16, "127.0.0.1")
  assert lr.ok
  let cr = makeConn(5000, addr gEndOnReset, nil, nil, nil, o1, o2)
  cr.a.src = lr.fd
  spawnTask runRelay(cr)
  let br = atomicLoad(gOk, moAcquire) + atomicLoad(gBad, moAcquire)
  spawnTask readPlain(o2, 0, 53, "a clean end after a failed read")
  shutdownWrite(o2)
  shutdownWrite(o1)
  waitChecks(br + 1)
  assert atomicLoad(gBad, moAcquire) == 0 and gReadFailed == 1, $gReadFailed
  closeFd(o1)
  closeFd(o2)
  closeFd(lr.fd)
  echo "PASS framer hooks: a sink writing its own prefix (re-entered), a failed read turned into a clean end"

  # A first span split through the alt block whose first batch fails (the
  # sink's peer is gone): the sink's close hook gets its own state back.
  gCloseSinkOk = 0
  gCloseSinkBad = 0
  let cs = makeConn(5000, nil, addr gCheckedSink, nil, nil, o1, o2)
  sinkState[array[StateWords, uint64]](addr cs.a)[][1] = StateMark
  let sAt = HeadRoom + 4
  assert ensurePayload(addr cs.a), "preload payload allocation"
  for i in 0 ..< 60_000: buf(addr cs.a)[sAt + i] = pat(i, 59)
  cs.a.spans[0] = Span(off: sAt, len: 60_000)
  cs.a.nspans = 1
  cs.a.bytes = 60_000
  lingerRst(o2)                                  # the sink's peer resets: the first write fails
  shutdownWrite(o1)
  let endsBefore = atomicLoad(gEnds, moAcquire)
  cs.hooks = addr gHooks
  spawnTask runRelay(cs)
  waitEnds(endsBefore + 1)
  var spinsS = 0
  while gCloseSinkOk + gCloseSinkBad == 0 and spinsS < 200:
    sleepMs(5)
    spinsS = spinsS + 1
  assert gCloseSinkOk == 1 and gCloseSinkBad == 0, $gCloseSinkOk & " " & $gCloseSinkBad
  closeFd(o1)
  echo "PASS a failed split: the sink's close hook gets its own state"

  # A direction that fails (a corrupt record) resets its sink: the peer
  # there sees an error, never a clean end of a truncated stream.
  var ending = 1
  let cf = makeConn(5000, addr gSmall, nil, nil, nil, o1, o2)
  closeFd(o2)                                    # the destination becomes TCP: a reset shows there
  closeFd(cf.up)
  var tr: cint = -1
  tcpPair(o2, tr)
  cf.up = tr
  cf.a.dst = tr
  cf.b.src = tr
  spawnTask runRelay(cf)
  let bf = atomicLoad(gOk, moAcquire) + atomicLoad(gBad, moAcquire)
  spawnTask readToEnd(o2, addr ending)
  var bad = default(array[16, byte])
  bad[0] = 0
  bad[1] = 4
  bad[2] = 7                                     # a nonzero pad byte: toyOpen refuses the record
  discard writeAll(o1, addr bad[0], bad.len, 5000)
  waitChecks(bf + 1)
  assert ending < 0, "the sink's peer saw " & $ending
  closeFd(o1)
  closeFd(o2)
  echo "PASS a failed direction resets its sink (no FIN for a truncated stream)"

  # ... and fails the other direction too: its destination (the failing
  # direction's source) sees a reset, not a FIN nor the sink's closing
  # record, though the other pump was idle (woken, its end is no clean one).
  var endA = 1
  var endB = 1
  var gotB = 0
  let cm = makeConn(5000, addr gSmall, nil, nil, addr gMark, o1, o2)
  closeFd(o1)
  closeFd(o2)
  closeFd(cm.fd)
  closeFd(cm.up)
  var tfd: cint = -1
  var tup: cint = -1
  tcpPair(o1, tfd)
  tcpPair(o2, tup)
  cm.fd = tfd
  cm.a.src = tfd
  cm.b.dst = tfd
  cm.up = tup
  cm.a.dst = tup
  cm.b.src = tup
  spawnTask runRelay(cm)
  let bm = atomicLoad(gOk, moAcquire) + atomicLoad(gBad, moAcquire)
  spawnTask readToEnd(o2, addr endA)
  spawnTask readCounting(o1, addr endB, addr gotB)
  discard writeAll(o1, addr bad[0], bad.len, 5000)
  waitChecks(bm + 2)
  assert endA < 0, "the failing direction's sink peer saw " & $endA
  assert endB < 0 and gotB == 0, "the other direction's sink peer saw " & $endB & " after " & $gotB & " bytes"
  closeFd(o1)
  closeFd(o2)
  echo "PASS a failed direction fails the other: its sink peer sees a reset, no FIN, no closing record"

  # A first span whose sink tail would pass the buffer's end: through alt.
  let ct = makeConn(5000, nil, addr gSmall, nil, nil, o1, o2)
  let tAt = BufCap - 102
  assert ensurePayload(addr ct.a), "preload payload allocation"
  for i in 0 ..< 100: buf(addr ct.a)[tAt + i] = pat(i, 61)
  ct.a.spans[0] = Span(off: tAt, len: 100)
  ct.a.nspans = 1
  ct.a.bytes = 100
  spawnTask runRelay(ct)
  shutdownWrite(o1)
  let bt = atomicLoad(gOk, moAcquire) + atomicLoad(gBad, moAcquire)
  spawnTask readFramed(o2, 100, 61, 4, 4, 4096, "a first span at the buffer's end")
  shutdownWrite(o2)
  waitChecks(bt + 1)
  assert atomicLoad(gBad, moAcquire) == 0
  closeFd(o1)
  closeFd(o2)
  echo "PASS a first span without tail room goes through alt"

  # Hooks: onBatch sees every byte; onEnd runs once, with the counters.
  resetHooks()
  let b7 = atomicLoad(gOk, moAcquire) + atomicLoad(gBad, moAcquire)
  let c7 = makeConn(5000, nil, nil, nil, nil, o1, o2)
  c7.hooks = addr gHooks
  spawnTask runRelay(c7)
  spawnTask writePlain(o1, 1 shl 20, 23, true)
  spawnTask readPlain(o2, 1 shl 20, 23, "hooks a")
  spawnTask writePlain(o2, 1 shl 19, 29, true)
  spawnTask readPlain(o1, 1 shl 19, 29, "hooks b")
  waitChecks(b7 + 4)
  waitEnds(1)
  assert atomicLoad(gBad, moAcquire) == 0
  assert atomicLoad(gEnds, moAcquire) == 1 and gEndReason == ord(erEof)
  assert atomicLoad(gBatchUp, moAcquire) == 1 shl 20 and atomicLoad(gBatchDown, moAcquire) == 1 shl 19
  assert gEndUp == 1 shl 20 and gEndDown == 1 shl 19
  closeFd(o1)
  closeFd(o2)
  echo "PASS hooks: every batch counted, one end (eof) with the counters"

  # Pairs that do not fit in place: relaid out, one copy per batch.
  let b8 = atomicLoad(gOk, moAcquire) + atomicLoad(gBad, moAcquire)
  let c8 = makeConn(5000, addr gFrame, addr gSmall, addr gSmall, addr gFrame, o1, o2)
  spawnTask runRelay(c8)
  spawnTask writeFramed(o1, 2 shl 20, 37, 60_000, 18, 16, true)
  spawnTask readFramed(o2, 2 shl 20, 37, 4, 4, 4096, "65535 -> 4096 relaid out")
  waitChecks(b8 + 1)
  spawnTask writeFramed(o2, 2 shl 20, 41, 4000, 4, 4, true)
  spawnTask readFramed(o1, 2 shl 20, 41, 18, 16, MaxRecord, "4/4 -> 18/16 relaid out")
  waitChecks(b8 + 2)
  assert atomicLoad(gBad, moAcquire) == 0
  closeFd(o1)
  closeFd(o2)
  echo "PASS relayout: 65535-byte records into a 4096-byte framer, a 4-byte head into an 18-byte one"

  # A first span longer than the sink's record (a handshake's leftover):
  # split, in order, with the marking sink's state carried across.
  let b9 = atomicLoad(gOk, moAcquire) + atomicLoad(gBad, moAcquire)
  let c9 = makeConn(5000, nil, addr gMark, nil, nil, o1, o2)
  let first = 60_000
  let at = HeadRoom + 4
  assert ensurePayload(addr c9.a), "preload payload allocation"
  for i in 0 ..< first: buf(addr c9.a)[at + i] = pat(i, 43)
  c9.a.spans[0] = Span(off: at, len: first)
  c9.a.nspans = 1
  c9.a.bytes = first
  spawnTask runRelay(c9)
  spawnTask writePlainFrom(o1, first, 1 shl 20, 43, true)
  spawnTask readFramed(o2, first + (1 shl 20), 43, 4, 4, 4096, "split first span")
  shutdownWrite(o2)
  waitChecks(b9 + 1)
  assert atomicLoad(gBad, moAcquire) == 0
  assert gEmpties == 2 and gFirstEmpty and gLastEmpty, $gEmpties
  closeFd(o1)
  closeFd(o2)
  echo "PASS a 60 000-byte first span into a 4096-byte framer: split, in order, state carried"
  expectRefused(nil, addr gWide, "a headroom beyond HeadRoom")
  expectRefused(nil, addr gTallHead, "a head beyond HeadRoom")
  expectRefused(nil, addr gHugeTail, "a record larger than the buffer")
  expectRefused(nil, addr gZero, "a zero geometry")

  # Idle timeout: nothing moves, the relay gives up and closes.
  resetHooks()
  let c4 = makeConn(150, nil, nil, nil, nil, o1, o2)
  c4.hooks = addr gHooks
  spawnTask runRelay(c4)
  var b = 0'u8
  let t0 = monoNow()
  let n = waitRead(o1, addr b, 1, 3000)
  let ms = (int64(monoNow()) - int64(t0)) div 1_000_000
  assert n <= 0
  assert ms >= 100 and ms < 2000
  waitEnds(1)
  assert gEndReason == ord(erIdle)
  closeFd(o1)
  closeFd(o2)
  echo "PASS idle timeout after ", ms, " ms, ending as idle"

  var spins = 0
  while liveConnections() > base and spins < 2000:
    sleepMs(1)
    spins = spins + 1
  assert liveConnections() == base
  assert liveAltBlocks() == 0, $liveAltBlocks()
  assert stopRelayPool()
  echo "PASS every connection block and alt block returned; cached mappings released"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
