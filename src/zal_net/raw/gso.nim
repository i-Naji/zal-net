## Sending datagrams in runs. A run is datagrams to one address laid out
## back to back; equal sizes (the last may be shorter) go out as one
## `sendmsg` with UDP_SEGMENT on Linux. A run of one can instead join a
## `sendmmsg` batch of single datagrams (`stageSingle`), which keeps replies
## to many clients in few system calls. Without GSO (other systems, Linux
## before 4.18, or a kernel that refuses it) a run is sent datagram by
## datagram.

import zal_net/private/sys/posix
import zal_net/net/sockaddr
import zal_net/raw/mmsg
import zal_net/private/sys/sock

const
  GsoCap* = 65000            # bytes per segmented send
  GsoMaxSegs* = 64           # UDP_MAX_SEGMENTS on older kernels
  GsoBufLen* = GsoCap + UdpMax + 256
  EAgainV = when defined(macosx): 35 else: 11
  ENoBufsV = when defined(macosx): 55 else: 105
  EOpNotSupp = when defined(macosx): 102 else: 95
  ENoProtoOpt = when defined(macosx): 42 else: 92

type
  GsoRun* = object
    buf*: unchecked ptr UncheckedArray[byte]   # GsoBufLen bytes, an anonymous mapping; set from a successful initRun to freeRun
    used*, seg*, count*: int
    fd*: cint
    dest*: SockAddrBuf

  GsoOut* = object
    ## Per sender (one engine thread): the batch of staged single
    ## datagrams, and whether GSO works here.
    outB*: unchecked ptr MmsgBatch   # set by initGsoOut
    outN*: int
    gsoOff*: bool


proc initRun*(r: var GsoRun): bool =
  r.buf = cast[ptr UncheckedArray[byte]](mapAnon(GsoBufLen))
  r.used = 0
  r.seg = 0
  r.count = 0
  result = r.buf != nil

proc freeRun*(r: var GsoRun) =
  if r.buf != nil: unmapAnon(r.buf, GsoBufLen)
  r.buf = nil

proc initGsoOut*(o: var GsoOut; singles: ptr MmsgBatch) =
  o.outB = singles
  o.outN = 0
  o.gsoOff = not gsoSupported()

proc sameAddr*(a, b: SockAddrBuf): bool =
  if a.len != b.len: return false
  let x = cast[ptr UncheckedArray[byte]](unsafeAddr a.ss)
  let y = cast[ptr UncheckedArray[byte]](unsafeAddr b.ss)
  var i = 0
  while i < int(a.len):
    if x[i] != y[i]: return false
    i = i + 1
  result = true

proc sendEach(r: ptr GsoRun) =
  var off = 0
  while off < r.used:
    let n = min(r.seg, r.used - off)
    discard sockSendto(r.fd, addr r.buf[off], csize_t(n), 0, addr r.dest.ss, r.dest.len)
    off = off + n

proc flushOut*(o: var GsoOut; fd: cint) =
  ## Send the staged single datagrams.
  if o.outN > 0:
    discard sendmmsgBatch(fd, o.outB[], o.outN)
    o.outN = 0

proc flushRun*(o: var GsoOut; r: ptr GsoRun; stageSingle: bool) =
  ## Send the run. With `stageSingle`, a run of one joins the batch instead.
  if r.count == 0: return
  if r.count == 1 and stageSingle:
    if o.outN == o.outB.cap: flushOut(o, r.fd)
    copyMem(addr o.outB.slots[o.outN].buf[0], addr r.buf[0], r.used)
    setOutgoing(o.outB[], o.outN, r.used, r.dest)
    o.outN = o.outN + 1
  elif r.count == 1 or o.gsoOff:
    if stageSingle: flushOut(o, r.fd)  # datagrams staged earlier go first
    sendEach(r)
  else:
    if stageSingle: flushOut(o, r.fd)
    let n = sendGso(r.fd, addr r.buf[0], culong(r.used), cint(r.seg), addr r.dest.ss, r.dest.len)
    if n < 0 and n != -EAgainV and n != -ENoBufsV:
      # Unsupported here, or refused for this run (a segment larger than
      # the path MTU): send it datagram by datagram.
      if n == -EOpNotSupp or n == -ENoProtoOpt: o.gsoOff = true
      sendEach(r)
  r.used = 0
  r.seg = 0
  r.count = 0

proc runRoom*(o: var GsoOut; r: ptr GsoRun; fd: cint; dest: SockAddrBuf; need: int;
              stageSingle: bool): ptr UncheckedArray[byte] =
  ## Where the next datagram to fd/dest goes, at most `need` bytes. A run
  ## to another address, or one without room, is sent first.
  if r.count > 0 and (r.fd != fd or r.used + need > GsoCap or not sameAddr(r.dest, dest)):
    flushRun(o, r, stageSingle)
  if r.count == 0:
    r.fd = fd
    r.dest = dest
  result = cast[ptr UncheckedArray[byte]](addr r.buf[r.used])

proc runCommit*(o: var GsoOut; r: ptr GsoRun; sz: int; stageSingle: bool) =
  ## Account for the `sz`-byte datagram just written at r.buf[r.used].
  if r.count == 0:
    r.seg = sz
    r.used = sz
    r.count = 1
  elif sz == r.seg:
    r.used = r.used + sz
    r.count = r.count + 1
  elif sz < r.seg:
    # A shorter datagram can only end a run.
    r.used = r.used + sz
    r.count = r.count + 1
    flushRun(o, r, stageSingle)
    return
  else:
    let at = r.used
    flushRun(o, r, stageSingle)
    moveMem(addr r.buf[0], addr r.buf[at], sz)
    r.seg = sz
    r.used = sz
    r.count = 1
  if r.count >= GsoMaxSegs: flushRun(o, r, stageSingle)
