import std/atomics
## ICMP echo ("ping") over net/ip: the unprivileged datagram ICMP sockets
## systems offer for it (always on macOS; on Linux for the groups in
## `net.ipv4.ping_group_range`), else a raw socket where the process has
## the privilege. IPv4 and IPv6; one socket per call; the wait parks like
## any read. Windows has neither: there `ping` runs the system's ICMP
## helper (IcmpSendEcho) on the blocking pool.
##
## ```nim
## let r = ping("1.1.1.1")
## if r.error == 0: echo r.source, " seq ", r.sequence, " in ", r.latencyUs, " µs"
## ```

import zal_net/errors
import zal_net/rt
import zal_net/raw/io
import zal_net/private/sys/posix
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/net/resolve
import zal_net/net/address
import zal_net/raw/ip
import zal_net/rt/sync
import zal_net/rt/blocking
import zal_net/private/sys/sock

const
  PingNoHost* = NetErrorBase - 20             ## the name did not resolve
  PingDenied* = NetErrorBase - 21             ## the system does not allow ICMP sockets here
  PingFailed* = NetErrorBase - 22             ## the socket or the send failed (or an ICMP error came back)

type
  PingReply* = object
    error*: int                   ## 0, PingNoHost, PingDenied, PingFailed or IoTimedOut
    source*: IpAddress            ## who answered
    sequence*: uint16
    ttl*: int                     ## the reply's TTL where the system shows it (IPv4 on macOS), else -1
    latencyUs*: int64


const
  EchoRequest4 = 8'u8
  EchoReply4 = 0'u8
  EchoRequest6 = 128'u8
  EchoReply6 = 129'u8

var gSeq: int

proc checksum(p: ptr UncheckedArray[byte]; n: int): uint16 =
  var sum = 0'u32
  var i = 0
  while i + 1 < n:
    sum = sum + (uint32(p[i]) shl 8) + uint32(p[i + 1])
    i = i + 2
  if i < n: sum = sum + (uint32(p[i]) shl 8)
  while (sum shr 16) != 0: sum = (sum and 0xffff) + (sum shr 16)
  result = not uint16(sum)

when defined(windows):
  type PingJob = object
    job: Job                      # first: the pool sees a Job
    v6: cint
    dst: array[16, byte]
    timeoutMs, payload: cint
    src: array[16, byte]
    rtt, ttl, rc: cint

  proc nnIcmpEcho(v6: cint; dst: pointer; timeoutMs, payload: cint; src: pointer;
                  rtt, ttl: ptr cint): cint {.importc: "nn_icmp_echo".}

  proc runPing(j: ptr Job) {.nimcall.} =
    let p = cast[ptr PingJob](j)
    p.rc = nnIcmpEcho(p.v6, addr p.dst[0], p.timeoutMs, p.payload, addr p.src[0], addr p.rtt, addr p.ttl)

  proc ping*(target: SocketAddress; timeoutMs = 1000; payload = 56): PingReply {.passive.} =
    ## One echo request to `target` (its port is ignored), through Windows'
    ## ICMP helper (no privileges needed), run on the blocking pool. The
    ## latency has millisecond resolution there.
    result = PingReply(error: IoTimedOut, ttl: -1)
    let ip = ip(target)
    let j = cast[ptr PingJob](newJob(sizeof(PingJob), runPing))
    j.v6 = cint(ord(ip.family == ipv6))
    copyMem(addr j.dst[0], unsafeAddr ip.bytes[0], 16)
    j.timeoutMs = cint(timeoutMs)
    j.payload = cint(max(0, min(payload, 1400)))
    let sequence = atomicFetchAdd(gSeq, 1, moRelaxed) + 1
    let sq = uint16(sequence and 0xffff)
    if not spawnBlocking(addr j.job):
      releaseJob(addr j.job)
      result.error = PingFailed
      return
    if awaitJob(addr j.job, afterMs(timeoutMs + 2000)) == wrReady:
      if j.rc == 0:
        var src = default(IpAddress)
        if j.v6 != 0: src = IpAddress(family: ipv6, bytes: j.src)
        else: src = ipv4(j.src[0], j.src[1], j.src[2], j.src[3])
        result = PingReply(error: 0, source: src, sequence: sq, ttl: int(j.ttl),
                           latencyUs: int64(j.rtt) * 1000)
      elif j.rc == -110: result.error = IoTimedOut
      else: result.error = PingFailed
    releaseJob(addr j.job)
else:
  proc ping*(target: SocketAddress; timeoutMs = 1000; payload = 56): PingReply {.passive.} =
    ## One echo request to `target` (its port is ignored), through an
    ## unprivileged ICMP datagram socket (net/ip).
    result = PingReply(error: IoTimedOut, ttl: -1)
    let v6 = address.family(target) == AF_INET6
    let proto = if v6: ipIcmpv6 else: ipIcmp
    var s = openIp(proto, v6, datagram = true, timeoutMs = timeoutMs)
    if not s.ok:
      s = openIp(proto, v6, timeoutMs = timeoutMs)
      if not s.ok:
        result.error = if denied(s): PingDenied else: PingFailed
        return
    let sequence = atomicFetchAdd(gSeq, 1, moRelaxed) + 1
    let sq = uint16(sequence and 0xffff)
    let id = uint16((getPid() xor (sequence shr 16)) and 0xffff)
    let size = 8 + max(0, min(payload, 1400))
    var pkt = default(array[1500, byte])
    pkt[0] = if v6: EchoRequest6 else: EchoRequest4
    pkt[4] = byte(id shr 8)
    pkt[5] = byte(id and 0xff)
    pkt[6] = byte(sq shr 8)
    pkt[7] = byte(sq and 0xff)
    var i = 8
    while i < size:
      pkt[i] = byte(i and 0xff)
      i = i + 1
    if not v6:   # the kernel fills the ICMPv6 checksum (it covers a pseudo header)
      let c = checksum(cast[ptr UncheckedArray[byte]](addr pkt[0]), size)
      pkt[2] = byte(c shr 8)
      pkt[3] = byte(c and 0xff)
    let t0 = monoNow()
    let deadline = afterMs(timeoutMs)
    if sendTo(s, addr pkt[0], size, ip(target), deadline) != size:
      close(s)
      result.error = PingFailed
      return
    var buf = default(array[1600, byte])
    var info = default(IpRecvInfo)
    while true:
      let n = recvFrom(s, addr buf[0], buf.len, addr info, deadline)
      if n < 0:
        result.error = if n == IoTimedOut: IoTimedOut else: PingFailed
        break
      let off = info.headerLen
      if n - off >= 8:
        let typ = buf[off]
        let rid = (uint16(buf[off + 4]) shl 8) or uint16(buf[off + 5])
        let rsq = (uint16(buf[off + 6]) shl 8) or uint16(buf[off + 7])
        # A raw socket sees every ICMP packet: match our identifier too (a
        # datagram socket's identifier is the kernel's).
        if typ == (if v6: EchoReply6 else: EchoReply4) and rsq == sq and (s.datagram or rid == id):
          result = PingReply(error: 0, source: info.source, sequence: sq, ttl: info.ttl,
                             latencyUs: (int64(monoNow()) - int64(t0)) div 1000)
          break
    close(s)

proc ping*(host: string; timeoutMs = 1000; payload = 56): PingReply {.passive.} =
  ## Ping `host` (a name resolves off the loop; its first address).
  let addrs = resolve(host, 0, 0.cint, SOCK_DGRAM)
  if addrs.len == 0:
    result = PingReply(error: PingNoHost, ttl: -1)
    return
  result = ping(addrs[0], timeoutMs, payload)
