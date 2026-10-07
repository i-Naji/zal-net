{.feature: "assumeSync".}
## The structs zal-net declares itself instead of importing (sys/types.nim
## and the public mirrors in net/sockaddr, net/mmsg, sys/sock and poller)
## have the sizes and field offsets their C definitions have (sys/nn_types.h,
## or the system header), on this platform.
import std/assertions
import std/syncio
import zal_net/private/sys/types
import zal_net/private/sys/sock
import zal_net/net/sockaddr
import zal_net/raw/mmsg

{.compile: "abi.c".}
proc nnAbi(q: cint): clong {.importc: "nn_abi".}

var checked = 0

proc same(q: int; nim: int) =
  let c = int(nnAbi(cint(q)))
  if c != nim: echo "ABI mismatch at query ", q, ": C says ", c, ", Nim ", nim
  assert c == nim
  checked = checked + 1

proc off(base, field: pointer): int = cast[int](field) - cast[int](base)

proc main() =
  var di = default(NnDinfo)
  same(20, sizeof(NnDinfo)); same(21, off(addr di, addr di.dst)); same(22, off(addr di, addr di.dstFamily))
  same(23, off(addr di, addr di.ifindex)); same(24, off(addr di, addr di.ttl)); same(25, off(addr di, addr di.tos))
  same(26, off(addr di, addr di.truncated))
  var pf = default(PollFd)
  same(30, sizeof(PollFd)); same(31, off(addr pf, addr pf.fd)); same(32, off(addr pf, addr pf.events))
  same(33, off(addr pf, addr pf.revents))
  var li = default(Linger)
  same(40, sizeof(Linger)); same(41, off(addr li, addr li.l_onoff)); same(42, off(addr li, addr li.l_linger))
  var mm = default(MmsgHdr)
  same(50, sizeof(MmsgHdr)); same(51, off(addr mm, addr mm.msg_hdr)); same(52, off(addr mm, addr mm.msg_len))
  when defined(windows):
    var io = default(IoVec)
    same(60, sizeof(IoVec)); same(61, off(addr io, addr io.iov_base)); same(62, off(addr io, addr io.iov_len))
    var mh = default(MsgHdr)
    same(70, sizeof(MsgHdr)); same(71, off(addr mh, addr mh.msg_name)); same(72, off(addr mh, addr mh.msg_namelen))
    same(73, off(addr mh, addr mh.msg_iov)); same(74, off(addr mh, addr mh.msg_iovlen)); same(75, off(addr mh, addr mh.msg_control))
    same(76, off(addr mh, addr mh.msg_controllen)); same(77, off(addr mh, addr mh.msg_flags))
    var ia = default(NnIfAddr)
    same(80, sizeof(NnIfAddr)); same(81, off(addr ia, addr ia.ip)); same(82, off(addr ia, addr ia.family))
    same(83, off(addr ia, addr ia.prefix))
    var ii = default(NnIfInfo)
    same(90, sizeof(NnIfInfo)); same(91, off(addr ii, addr ii.index)); same(92, off(addr ii, addr ii.name))
    same(93, off(addr ii, addr ii.mtu)); same(94, off(addr ii, addr ii.flags)); same(95, off(addr ii, addr ii.naddrs))
    same(96, off(addr ii, addr ii.addrs))
  echo "PASS ", checked, " sizes and offsets agree with C"

main()
