## Batched UDP: sendmmsg/recvmmsg through MmsgBatch, and on Linux one GSO run
## that must arrive as separate datagrams.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/raw/mmsg


import zal_net/private/sys/sock
proc sleepMsBlocking(ms: int) = sleepUs(ms * 1000)

proc recvAll(fd: cint; b: var MmsgBatch; want: int): int =
  ## Datagrams received within about a second.
  result = 0
  var tries = 0
  while result < want and tries < 200:
    let n = recvmmsgBatch(fd, b, MSG_DONTWAIT)
    if n > 0:
      var i = 0
      while i < n:
        assert datagramLen(b, i) == 100 + result
        result = result + 1
        i = i + 1
    else:
      tries = tries + 1
      sleepMsBlocking(5)


proc main() {.passive.} =
  let rx = tryListenUdp(0, bindAddr = "127.0.0.1")
  assert rx.ok
  let rxPort = localPort(rx.fd)
  assert rxPort != 0
  var dest = default(SockAddrBuf)
  assert parseNumeric("127.0.0.1", rxPort, AF_INET, dest)
  var family: cint = 0
  let tx = openUdpSocket(family)
  assert tx >= 0
  if family == AF_INET6:
    var d6 = default(SockAddrBuf)
    let ip = [byte 127, 0, 0, 1]
    assert setIpAddr(d6, ip, rxPort, AF_INET6)
    dest = d6

  var outB = default(MmsgBatch)
  var inB = default(MmsgBatch)
  assert initBatch(outB, 8)
  assert initBatch(inB, 8, recvCtrl = true)
  var i = 0
  while i < 3:
    setOutgoing(outB, i, 100 + i, dest)
    i = i + 1
  assert sendmmsgBatch(tx, outB, 3) == 3
  assert recvAll(rx.fd, inB, 3) == 3
  echo "PASS sendmmsg/recvmmsg batch"

  when defined(linux):
    if not gsoSupported():
      var run = default(array[300, byte])
      assert sendGso(tx, addr run[0], culong(300), 100.cint, addr dest.ss, dest.len) < 0
      echo "SKIP GSO: not on this kernel (before 4.18, or NN_LINUX_COMPAT=1); sendGso refuses"
    else:
      # One run of three 100-byte segments.
      var run = default(array[300, byte])
      let n = sendGso(tx, addr run[0], culong(300), 100.cint, addr dest.ss, dest.len)
      assert n == 300
      var got = 0
      var tries = 0
      while got < 3 and tries < 200:
        let m = recvmmsgBatch(rx.fd, inB, MSG_DONTWAIT)
        if m > 0:
          var k = 0
          while k < m:
            let seg = groSegment(inB, k)
            let len = datagramLen(inB, k)
            if seg > 0: got = got + (len + seg - 1) div seg
            else:
              assert len == 100
              got = got + 1
            k = k + 1
        else:
          tries = tries + 1
          sleepMsBlocking(5)
      assert got == 3
      echo "PASS GSO run arrives as three datagrams"

  freeBatch(outB)
  freeBatch(inB)
  closeFdRaw(tx)
  closeFdRaw(rx.fd)
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
