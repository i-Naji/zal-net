## recvmmsg / sendmmsg slot pool. A receive batch carries a control buffer
## per slot, so a socket with UDP_GRO reports the segment size of each
## coalesced datagram (`groSegment`); every segment is a separate packet.

import std/assertions
from zal_net/errors import InvalidInput
import zal_net/net/sockaddr
import zal_net/private/sys/posix

{.compile: "../private/sys/nn_udp.c".}

const
  UdpMax* = 65535
  MaxBatchSlots* = 1024
  CtrlLen = 64

when defined(windows):
  type
    MsgHdr* = object              ## the Linux struct msghdr; sys/win/nn_win.c reads it
      msg_name*: nil pointer
      msg_namelen*: cuint
      msg_iov*: nil ptr IoVec
      msg_iovlen*: csize_t
      msg_control*: nil pointer
      msg_controllen*: csize_t
      msg_flags*: cint
else:
  type
    MsgHdr* {.importc: "struct msghdr", header: "<sys/socket.h>".} = object
      msg_name*: nil pointer
      msg_namelen*: cuint
      msg_iov*: nil ptr IoVec
      msg_iovlen*: csize_t
      msg_control*: nil pointer
      msg_controllen*: csize_t
      msg_flags*: cint

type
  BatchResult* = object
    sent*: int                   ## packets accepted by the kernel
    error*: int                  ## zero on success; may accompany partial progress

  MmsgHdr* = object   # struct mmsghdr (struct nn_mmsghdr on Darwin)
    msg_hdr*: MsgHdr
    msg_len*: cuint

  MsgSlot* = object
    iov*: IoVec
    name*: SockaddrStorage
    ctrl: array[CtrlLen, byte]
    buf*: array[UdpMax, byte]

  MmsgBatch* = object
    ## `hdrs` is the contiguous vector handed to the kernel. Every pointer
    ## in it is bound once to `slots`; neither is resized later. The slots
    ## are an anonymous mapping: each has room for a 64 KiB datagram, but
    ## only the pages real datagrams reach become resident.
    cap*: int
    used: int
    ctrl: bool
    hdrs*: seq[MmsgHdr]
    slots*: unchecked ptr UncheckedArray[MsgSlot]   # set while cap > 0

proc batchResult*(sent, error: int): BatchResult {.inline.} =
  BatchResult(sent: sent, error: error)

# nn_recvmmsg/nn_sendmmsg: Linux's calls (loops over recvmsg/sendmsg on
# kernels without them, sys/nn_linux.c), loops on Darwin and Windows.
when defined(macosx):
  {.compile: "../private/sys/nn_mmsg_darwin.c".}
proc recvmmsg(fd: cint; vec: pointer; vlen: cuint; flags: cint; timeout: nil pointer): cint {.
  importc: "nn_recvmmsg".}
proc sendmmsg(fd: cint; vec: pointer; vlen: cuint; flags: cint): cint {.importc: "nn_sendmmsg".}

proc recvmmsgRaw*(fd: cint; vec: pointer; vlen: cuint; flags: cint): int =
  result = int(recvmmsg(fd, vec, vlen, flags, nil))

proc sendmmsgRaw*(fd: cint; vec: pointer; vlen: cuint; flags: cint): int =
  result = int(sendmmsg(fd, vec, vlen, flags))

# groOn: 1 when UDP_GRO was enabled on `fd` (Linux); 0 elsewhere.
# sendGso: `len` bytes at `buf` sent to `dest` as `seg`-byte datagrams (the
# last may be shorter) with one sendmsg. Bytes sent, or -errno; -EOPNOTSUPP
# where UDP segmentation offload does not exist (`gsoSupported`).
proc groOn*(fd: cint): cint {.importc: "nn_udp_gro_on".}
proc nnUdpGsoOk(): cint {.importc: "nn_udp_gso_ok".}
proc gsoSupported*(): bool =
  ## The kernel segments UDP_SEGMENT sends (Linux 4.18 and later; probed
  ## once: an older kernel would send one oversized datagram instead).
  result = nnUdpGsoOk() != 0
proc sendGso*(fd: cint; buf: pointer; len: culong; seg: cint; dest: pointer;
              destLen: cuint): clong {.importc: "nn_udp_send_gso".}

proc groSize(msghdr: pointer): cint {.importc: "nn_udp_gro_size".}

proc initBatch*(b: var MmsgBatch; cap: int; recvCtrl = false): bool =
  ## `recvCtrl` gives every slot a control buffer for GRO segment sizes.
  if cap < 1 or cap > MaxBatchSlots or b.cap != 0: return false
  b.cap = cap
  b.used = 0
  b.ctrl = recvCtrl
  b.slots = cast[ptr UncheckedArray[MsgSlot]](mapAnon(cap * sizeof(MsgSlot)))
  if b.slots == nil:
    b.cap = 0
    return false
  b.hdrs = newSeq[MmsgHdr](cap)
  var i = 0
  while i < cap:
    b.slots[i].iov.iov_base = addr b.slots[i].buf[0]
    b.slots[i].iov.iov_len = csize_t(UdpMax)
    b.hdrs[i].msg_hdr.msg_name = addr b.slots[i].name
    b.hdrs[i].msg_hdr.msg_namelen = cuint(sizeof(SockaddrStorage))
    b.hdrs[i].msg_hdr.msg_iov = addr b.slots[i].iov
    b.hdrs[i].msg_hdr.msg_iovlen = 1
    if recvCtrl:
      b.hdrs[i].msg_hdr.msg_control = addr b.slots[i].ctrl[0]
      b.hdrs[i].msg_hdr.msg_controllen = csize_t(CtrlLen)
    else:
      b.hdrs[i].msg_hdr.msg_control = nil
      b.hdrs[i].msg_hdr.msg_controllen = 0
    b.hdrs[i].msg_hdr.msg_flags = 0
    b.hdrs[i].msg_len = 0
    i = i + 1
  result = true

proc freeBatch*(b: var MmsgBatch) =
  if b.slots != nil: unmapAnon(b.slots, b.cap * sizeof(MsgSlot))
  b.slots = nil
  b.cap = 0
  b.used = 0
  b.hdrs = @[]

proc recvmmsgBatch*(fd: cint; b: var MmsgBatch; flags: cint; maximum = 0): int =
  ## Receive at most maximum slots (0: allocated capacity). The optional
  ## bound never changes b.cap: freeBatch must unmap the complete allocation.
  ## Only the address lengths the kernel shortened last time need resetting.
  if b.cap < 1 or b.cap > MaxBatchSlots or b.hdrs.len < b.cap or b.slots == nil or
     maximum < 0 or maximum > b.cap: return InvalidInput
  let count = if maximum == 0: b.cap else: maximum
  var i = 0
  while i < b.used:
    b.hdrs[i].msg_hdr.msg_namelen = cuint(sizeof(SockaddrStorage))
    b.hdrs[i].msg_hdr.msg_flags = 0
    if b.ctrl: b.hdrs[i].msg_hdr.msg_controllen = csize_t(CtrlLen)
    i = i + 1
  result = recvmmsgRaw(fd, addr b.hdrs[0], cuint(count), flags)
  b.used = if result > 0: result else: 0

proc datagramLen*(b: MmsgBatch; i: int): int {.inline.} =
  int(b.hdrs[i].msg_len)

proc groSegment*(b: var MmsgBatch; i: int): int =
  ## Segment size of a GRO-coalesced datagram `i`, or 0 for a plain one.
  if not b.ctrl: return 0
  result = int(groSize(addr b.hdrs[i].msg_hdr))

proc peerLen*(b: MmsgBatch; i: int): cuint {.inline.} =
  b.hdrs[i].msg_hdr.msg_namelen

proc setOutgoing*(b: var MmsgBatch; i: int; len: int; peer: SockAddrBuf) =
  ## Address and length of outgoing datagram `i`.
  copyMem(addr b.slots[i].name, unsafeAddr peer.ss, int(peer.len))
  b.slots[i].iov.iov_len = csize_t(len)
  b.hdrs[i].msg_hdr.msg_namelen = peer.len
  b.hdrs[i].msg_hdr.msg_flags = 0
  b.hdrs[i].msg_len = 0

proc sendmmsgBatch*(fd: cint; b: var MmsgBatch; n: int): int =
  ## Retry remaining entries; Linux sendmmsg may send a prefix.
  result = 0
  var off = 0
  while off < n:
    let got = sendmmsgRaw(fd, addr b.hdrs[off], cuint(n - off), 0)
    if got <= 0:
      if result == 0: result = got
      return
    off = off + got
    result = result + got
