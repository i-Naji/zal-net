## GSO runs: a run of equal datagrams with a shorter last one, a size change
## that starts a new run, a run of one staged into the sendmmsg batch, and a
## switch of destination. Every datagram must arrive intact (on Linux as one
## segmented send; elsewhere one by one).
import std/assertions
import std/syncio
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/raw/mmsg
import zal_net/raw/io
import zal_net/raw/gso

import zal_net/private/sys/sock

proc receiver(): (cint, SockAddrBuf) =
  var fam = AF_INET
  let fd = openUdpSocket(fam)
  assert fd >= 0
  var sa = default(SockAddrBuf)
  let lo = [127'u8, 0, 0, 1]
  assert setIpAddr(sa, lo, 0'u16, fam)   # v4-mapped on the dual-stack socket
  assert sockBind(fd, addr sa.ss, sa.len) == 0
  setPort(sa, localPort(fd))
  result = (fd, sa)

proc drain(fd: cint; sizes: var seq[int]; firsts: var seq[byte]) =
  var buf = default(array[65536, byte])
  var idle = 0
  while idle < 50:
    let n = sockRecvfrom(fd, addr buf[0], csize_t(buf.len), MSG_DONTWAIT, nil, nil)
    if n > 0:
      sizes.add n
      firsts.add buf[0]
      idle = 0
    else:
      sleepUs(1000)
      idle = idle + 1

proc put(o: var GsoOut; r: ptr GsoRun; fd: cint; dest: SockAddrBuf; size: int; tag: byte; single: bool) =
  let p = runRoom(o, r, fd, dest, size, single)
  var i = 0
  while i < size:
    p[i] = tag
    i = i + 1
  runCommit(o, r, size, single)

proc main() =
  var fam = AF_INET
  let tx = openUdpSocket(fam)
  assert tx >= 0
  let (rx1, a1) = receiver()
  let (rx2, a2) = receiver()
  var singles = default(MmsgBatch)
  assert initBatch(singles, 16)
  var o = default(GsoOut)
  initGsoOut(o, addr singles)
  var r = default(GsoRun)
  assert initRun(r)

  # 10 x 1000 then 300 to rx1 (one run, a shorter last one ends it).
  var k = 0
  while k < 10:
    put(o, addr r, tx, a1, 1000, byte(k), false)
    k = k + 1
  put(o, addr r, tx, a1, 300, 99, false)
  # A larger datagram after a flushed run, then a switch to rx2.
  put(o, addr r, tx, a1, 1400, 100, false)
  put(o, addr r, tx, a2, 500, 101, false)
  flushRun(o, addr r, false)
  # A run of one, staged into the sendmmsg batch.
  put(o, addr r, tx, a2, 700, 102, true)
  flushRun(o, addr r, true)
  flushOut(o, tx)

  var s1: seq[int] = @[]
  var f1: seq[byte] = @[]
  drain(rx1, s1, f1)
  var s2: seq[int] = @[]
  var f2: seq[byte] = @[]
  drain(rx2, s2, f2)
  assert s1.len == 12
  k = 0
  while k < 10:
    assert s1[k] == 1000 and f1[k] == byte(k)
    k = k + 1
  assert s1[10] == 300 and f1[10] == 99
  assert s1[11] == 1400 and f1[11] == 100
  assert s2 == @[500, 700] and f2 == @[101'u8, 102]
  echo "PASS runs, size changes, staging, destinations (gso ", (if o.gsoOff: "off" else: "on"), ")"
  freeRun(r)
  freeBatch(singles)

main()
