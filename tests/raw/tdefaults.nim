## Raw owners default to closed. Transfers invalidate the source and repeated
## close cannot close a later descriptor, descriptor zero included.
import std/[assertions, syncio]
import zal_net/[rt, errors], zal_net/raw/io
import zal_net/raw/[tcp, unix, udp, ip, tun]
import zal_net/private/os

proc checkDefaults() {.passive.} =
  var tcp = default(TcpStream)
  var unix = default(UnixStream)
  var udp = default(UdpSocket)
  var ud = default(UnixDatagram)
  var ip = default(IpSocket)
  var tun = default(TunDevice)
  var tl = default(TcpListener)
  var ul = default(UnixListener)
  assert not tcp.isOpen and not unix.isOpen
  assert not udp.ok and not ud.ok and not ip.ok and not tun.ok
  close(addr tcp)
  close(addr unix)
  close(udp)
  close(ud)
  close(ip)
  close(tun)
  assert close(tl) and close(ul)
  closeNow(tl)
  closeNow(ul)
  var b = 0'u8
  assert recvInto(addr tcp, addr b, 0) == 0
  assert sendFrom(addr tcp, addr b, -1) == InvalidInput
  assert recvInto(addr tcp, addr b, 1) < 0
  assert nativeHandle(tcp) == -1

when not defined(windows):
  proc cDup(fd: cint): cint {.importc: "dup", header: "<unistd.h>".}
  proc cDup2(fd, target: cint): cint {.importc: "dup2", header: "<unistd.h>".}
  proc socketPair(domain, kind, protocol: cint; pair: ptr array[2, cint]): cint {.importc: "socketpair", header: "<sys/socket.h>".}
  var pair = [-1.cint, -1.cint]
  assert socketPair(1, 1, 0, addr pair) == 0
  let stdinCopy = cDup(0)
  assert cDup2(pair[0], 0) == 0
  if pair[0] != 0: discard sockClose(pair[0])
  var descriptor = 0.cint
  var source = default(TcpStream)
  var unused = default(TcpStream)
  close(addr unused) # must not close the live socket at descriptor zero
  assert adoptTcp(addr source, descriptor)
  assert descriptor == -1 and nativeHandle(source) == 0
  var target = takeTcp(addr source)
  assert not source.isOpen and target.isOpen
  close(addr source)
  var value = 0x3a'u8
  assert writeSome(nativeHandle(target), addr value, 1) == 1
  var received = 0'u8
  assert readSome(pair[1], addr received, 1) == 1 and received == value
  var other = pair[1]
  assert not adoptTcp(addr target, other) and other == pair[1]
  let detached = takeNativeHandle(addr target)
  assert detached == 0 and not target.isOpen
  close(addr target)
  assert writeSome(detached, addr value, 1) == 1
  discard sockClose(detached)
  if stdinCopy >= 0:
    assert cDup2(stdinCopy, 0) == 0
    discard sockClose(stdinCopy)
  discard sockClose(pair[1])
  assert readSome(-1, addr received, 1) == -9 # EBADF retained, not collapsed
  echo "PASS raw owners closed by default, descriptor zero, failed adoption, transfer and detachment"

assert runMain(checkDefaults())
