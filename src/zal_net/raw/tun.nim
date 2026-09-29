## TUN and TAP devices: IP packets (TUN) or Ethernet frames (TAP) in and
## out of the kernel's network stack, through the same parks as sockets.
## Creating one needs privileges (root, CAP_NET_ADMIN on Linux,
## administrator rights on Windows).
##
## - Linux: /dev/net/tun, TUN or TAP, without the packet-information
##   header: a read is exactly one packet or frame.
## - macOS: utun (TUN only; macOS has no TAP), whose 4-byte address-family
##   header is added and removed here, so reads and writes carry plain IP
##   packets on both systems.
## - Windows: Wintun (https://www.wintun.net), TUN only: wintun.dll must
##   sit beside the program (or in System32), and creating a device needs
##   administrator rights. The device is a new network adapter, removed
##   when it is closed; `name` is its interface alias. Reads park on a wake
##   socket a waiter thread signals (Wintun signals an event, not a socket).
##
## Bring the device up and give it addresses with net/interfaces
## (`setInterfaceUp`, `setInterfaceMtu`, `addAddress4`) or the system's
## tools.
##
## ```nim
## var t = openTun()                     # "tun0", "utun5"...
## var buf = default(array[65536, byte])
## while true:
##   let n = recvInto(t, addr buf[0], buf.len)   # one IP packet
##   ...
## ```

import zal_net/private/socketowner
import std/oserrors
import zal_net/errors
import zal_net/rt
import zal_net/raw/io
import zal_net/private/sys/posix
import zal_net/net/sockaddr
import zal_net/raw/socket
import zal_net/raw/fdops

type
  TunDevice* = object
    socket: SocketOwner          ## sole descriptor owner; zero initialization is closed
    name*: string                 ## the interface's name
    tap*: bool
    timeoutMs*: int               ## idle limit per operation (0: none)
    error*: string
    wintun: nil pointer           # Windows: the adapter and its session

  IoVecT = object
    base: pointer
    len: csize_t

when defined(windows):
  {.compile: "../private/sys/win/nn_wintun.c".}
  proc nnWintunOpen(name: cstring; err: ptr cint; code: ptr cuint; alias: ptr char; cap: cint;
                    wake: ptr cint): nil pointer {.importc: "nn_wintun_open".}
  proc nnWintunRecv(h: pointer; p: pointer; n: csize_t): int {.importc: "nn_wintun_recv".}
  proc nnWintunSend(h: pointer; p: pointer; n: csize_t): int {.importc: "nn_wintun_send".}
  proc nnWintunClose(h: pointer) {.importc: "nn_wintun_close".}

when not defined(windows):
  proc cOpen(path: cstring; flags: cint): cint {.importc: "open", header: "<fcntl.h>", varargs.}
  proc cIoctl(fd: cint; req: culong; arg: pointer): cint {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}
  proc cSocket(af, kind, proto: cint): cint {.importc: "socket", header: "<sys/socket.h>".}
  proc cConnect(fd: cint; sa: pointer; len: cuint): cint {.importc: "connect", header: "<sys/socket.h>".}
  proc cGetsockopt(fd, level, opt: cint; v: pointer; len: ptr cuint): cint {.importc: "getsockopt", header: "<sys/socket.h>".}
  proc cReadv(fd: cint; iov: pointer; n: cint): int {.importc: "readv", header: "<sys/uio.h>".}
  proc cWritev(fd: cint; iov: pointer; n: cint): int {.importc: "writev", header: "<sys/uio.h>".}

const
  EAcces = 13
  EPerm = 1

proc fd(t: TunDevice): cint {.inline.} = handle(t.socket)

proc ok*(t: TunDevice): bool {.inline.} = t.fd >= 0
proc nativeHandle*(t: TunDevice): cint {.inline.} = t.fd

proc fail(t: var TunDevice; what: string) =
  let err = int(osLastError())
  t.error = if err == EAcces or err == EPerm: "not permitted" else: what & " (errno " & $err & ")"

proc denied*(t: TunDevice): bool = t.fd < 0 and t.error == "not permitted"

proc openTun*(name = ""; tap = false; timeoutMs = 0): TunDevice =
  ## A new device (or `name`: Linux "tun3"/"tap0", macOS "utun7"; "" lets
  ## the system pick).
  result = TunDevice(socket: ownedSocket(-1), tap: tap, timeoutMs: timeoutMs)
  when defined(linux):
    let fd = cOpen("/dev/net/tun", 2.cint or 0o4000.cint)     # O_RDWR | O_NONBLOCK
    if fd < 0:
      fail(result, "/dev/net/tun")
      return
    var ifr = default(array[40, byte])                      # struct ifreq
    var i = 0
    while i < name.len and i < 15:
      ifr[i] = byte(name[i])
      i = i + 1
    let flags = (if tap: 0x0002'u16 else: 0x0001'u16) or 0x1000'u16   # IFF_TAP/IFF_TUN | IFF_NO_PI
    ifr[16] = byte(flags and 0xff)
    ifr[17] = byte(flags shr 8)
    if cIoctl(fd, culong(0x400454ca'u32), addr ifr[0]) != 0:           # TUNSETIFF
      fail(result, "TUNSETIFF")
      discard closeRaw(fd)
      return
    var n = ""
    i = 0
    while i < 16 and ifr[i] != 0:
      n.add char(ifr[i])
      i = i + 1
    result.name = n
    result.socket = ownedSocket(fd)
  elif defined(macosx):
    if tap:
      result.error = "macOS has no TAP devices"
      return
    let fd = cSocket(32.cint, SOCK_DGRAM, 2.cint)           # PF_SYSTEM, SYSPROTO_CONTROL
    if fd < 0:
      fail(result, "socket(PF_SYSTEM)")
      return
    var info = default(array[100, byte])                    # struct ctl_info
    let ctl = "com.apple.net.utun_control"
    var i = 0
    while i < ctl.len:
      info[4 + i] = byte(ctl[i])
      i = i + 1
    if cIoctl(fd, culong(0xc0644e03'u32), addr info[0]) != 0:          # CTLIOCGINFO
      fail(result, "CTLIOCGINFO")
      discard closeRaw(fd)
      return
    var unit = 0'u32
    if name.len > 4 and name[0 .. 3] == "utun":
      var k = 4
      while k < name.len:
        unit = unit * 10 + uint32(ord(name[k]) - ord('0'))
        k = k + 1
      unit = unit + 1
    var sc = default(array[32, byte])                       # struct sockaddr_ctl
    sc[0] = 32
    sc[1] = 32                                              # AF_SYSTEM
    sc[2] = 2                                               # AF_SYS_CONTROL
    copyMem(addr sc[4], addr info[0], 4)                    # ctl_id
    copyMem(addr sc[8], addr unit, 4)                       # sc_unit
    if cConnect(fd, addr sc[0], 32) != 0:
      fail(result, "connect(utun)")
      discard closeRaw(fd)
      return
    var ifname = default(array[32, char])
    var len = cuint(ifname.len)
    discard cGetsockopt(fd, 2.cint, 2.cint, addr ifname[0], addr len)   # UTUN_OPT_IFNAME
    var n = ""
    i = 0
    while i < ifname.len and ifname[i] != '\0':
      n.add ifname[i]
      i = i + 1
    result.name = n
    setNonblock(fd)
    result.socket = ownedSocket(fd)
  elif defined(windows):
    if tap:
      result.error = "Wintun has no TAP devices"
      return
    var err: cint = 0
    var code: cuint = 0
    var alias = default(array[260, char])
    var wake: cint = -1
    var n = name
    let h = nnWintunOpen(n.toCString, addr err, addr code, addr alias[0], cint(alias.len), addr wake)
    if h == nil:
      result.error =
        if err == 1: "wintun.dll not found (beside the program or in System32)"
        elif err == 2 and code == 5: "not permitted"
        elif err == 2: "WintunCreateAdapter failed (error " & $code & ")"
        elif err == 3: "WintunStartSession failed (error " & $code & ")"
        else: "out of resources"
      return
    var i = 0
    while i < alias.len and alias[i] != '\0':
      result.name.add alias[i]
      i = i + 1
    if result.name.len == 0: result.name = (if name.len > 0: name else: "nimony")
    result.wintun = h
    result.socket = ownedSocket(wake)
  else:
    result.error = "no TUN devices on this system"

proc interrupt*(t: TunDevice): bool =
  ## Descriptor-wide wakeup is unavailable; use token-aware I/O cancellation.
  result = interruptFd(t.fd)

proc close*(t: var TunDevice) =
  when defined(windows):
    let h = t.wintun
    if h != nil:
      nnWintunClose(h)               # the waiter first: it writes to the wake socket
      t.wintun = nil
  if t.fd >= 0:
    closeFd(takeHandle(t.socket))

proc readOnce(t: TunDevice; p: pointer; n: int): int =
  ## Packet length, IoAgain, or a negative native/library error.
  if n < 0: return InvalidInput
  if n == 0: return 0
  if t.fd < 0: return ResourceClosed
  when defined(windows):
    let h = t.wintun
    if h == nil: return ResourceClosed
    result = nnWintunRecv(h, p, csize_t(n))
    if result == -259: result = IoAgain  # ERROR_NO_MORE_ITEMS
  elif defined(macosx):
    while true:
      var hdr = default(array[4, byte])
      var iov = [IoVecT(base: addr hdr[0], len: 4), IoVecT(base: p, len: csize_t(n))]
      let k = cReadv(t.fd, addr iov[0], 2)
      if k >= 4: return k - 4
      if k >= 0: continue                     # a runt: skip it
      let err = int(osLastError())
      if err == EIntr: continue
      return (if err == EAgain: IoAgain else: -err)
  else:
    result = readSome(t.fd, p, n)

proc writeOnce(t: TunDevice; p: pointer; n: int): int =
  if n < 0: return InvalidInput
  if n == 0: return 0
  if t.fd < 0: return ResourceClosed
  when defined(windows):
    let h = t.wintun
    if h == nil: return ResourceClosed
    result = nnWintunSend(h, p, csize_t(n))
    if result == -111: result = IoAgain  # ERROR_BUFFER_OVERFLOW
  elif defined(macosx):
    let b = cast[ptr UncheckedArray[byte]](p)
    var hdr = [0'u8, 0, 0, 2]                 # AF_INET
    if n > 0 and (b[0] shr 4) == 6: hdr[3] = 30   # AF_INET6
    var iov = [IoVecT(base: addr hdr[0], len: 4), IoVecT(base: p, len: csize_t(n))]
    while true:
      let k = cWritev(t.fd, addr iov[0], 2)
      if k >= 4: return k - 4
      if k >= 0: return NoProgress
      let err = int(osLastError())
      if err == EIntr: continue
      return (if err == EAgain: IoAgain else: -err)
  else:
    result = writeSome(t.fd, p, n)

proc recvInto*(t: TunDevice; p: pointer; n: int; deadline = never): int {.passive.} =
  ## One IP packet (TAP: one Ethernet frame) into p: its length, or <0.
  let d = limit(t.timeoutMs, deadline)
  var res = 0
  while true:
    let k = readOnce(t, p, n)
    if k != IoAgain: return k
    parkPoll(t.fd, {evRead}, d, res)
    if res <= 0: return (if res < 0: res else: -1)

proc sendFrom*(t: TunDevice; p: pointer; n: int; deadline = never): int {.passive.} =
  ## One IP packet (TAP: one Ethernet frame) into the kernel: its length,
  ## or <0.
  let d = limit(t.timeoutMs, deadline)
  var res = 0
  while true:
    let k = writeOnce(t, p, n)
    if k != IoAgain: return k
    when defined(windows):
      # A full Wintun ring signals nothing when it drains: look again soon.
      if not (d == never) and d <= monoNow(): return IoTimedOut
      sleepMs(1)
    else:
      parkPoll(t.fd, {evWrite}, d, res)
      if res <= 0: return (if res < 0: res else: -1)

template recv*(t: TunDevice; buf: var openArray[byte]): int = recvInto(t, dataPtr(buf), buf.len)
template send*(t: TunDevice; buf: openArray[byte]): int = sendFrom(t, dataPtr(buf), buf.len)
