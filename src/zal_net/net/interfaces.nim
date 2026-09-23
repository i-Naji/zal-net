## Network interfaces: name, index, MTU, flags and IP addresses (with
## their prefix lengths), from getifaddrs. A snapshot per call; no I/O
## beyond the system calls, so it may run on a loop.
##
## ```nim
## for i in interfaces():
##   if isUp(i) and not isLoopback(i): echo i.name, " ", i.index, " mtu ", i.mtu
## ```

import zal_net/buffers
import zal_net/net/sockaddr
import zal_net/net/address
import zal_net/private/sys/types

type
  InterfaceFlag* = enum
    ifUp, ifBroadcast, ifLoopback, ifPointToPoint, ifRunning, ifMulticast

  InterfaceAddress* = object
    ip*: IpAddress
    prefixLen*: int

  NetworkInterface* = object
    index*: uint32                ## 0 when there is no such interface
    name*: string
    mtu*: int                     ## -1 when unknown
    flags*: set[InterfaceFlag]
    addresses*: seq[InterfaceAddress]


when defined(windows):
  proc nnIfList(outp: ptr NnIfInfo; max: cint): cint {.importc: "nn_if_list".}
else:
  type
    IfAddrs {.importc: "struct ifaddrs", header: "<ifaddrs.h>".} = object
      ifa_next: nil ptr IfAddrs
      ifa_name: nil cstring
      ifa_flags: cuint
      ifa_addr: nil pointer         # struct sockaddr *
      ifa_netmask: nil pointer
    IfAddrsList = nil ptr IfAddrs

  proc getifaddrs(res: ptr IfAddrsList): cint {.importc, header: "<ifaddrs.h>".}
  proc freeifaddrs(p: ptr IfAddrs) {.importc, header: "<ifaddrs.h>".}
  proc ifNametoindex(name: cstring): cuint {.importc: "if_nametoindex", header: "<net/if.h>".}
  proc ifIndextoname(idx: cuint; buf: cstring): cstring {.importc: "if_indextoname", header: "<net/if.h>".}
  proc cSocket(af, kind, proto: cint): cint {.importc: "socket", header: "<sys/socket.h>".}
  proc cClose(fd: cint): cint {.importc: "close", header: "<unistd.h>".}
  proc cIoctl(fd: cint; req: culong; arg: pointer): cint {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

  const
    IffUp = 0x1'u32
    IffBroadcast = 0x2'u32
    IffLoopback = 0x8'u32
    IffPointToPoint = 0x10'u32
    IffRunning = 0x40'u32
    IffMulticast = (when defined(linux): 0x1000'u32 else: 0x8000'u32)
    SiocGifMtu = (when defined(linux): 0x8921'u64 else: 0xc0206933'u64)

proc isUp*(i: NetworkInterface): bool {.inline.} = ifUp in i.flags
proc isLoopback*(i: NetworkInterface): bool {.inline.} = ifLoopback in i.flags
proc isMulticast*(i: NetworkInterface): bool {.inline.} = ifMulticast in i.flags

when defined(windows):
  proc interfaces*(): seq[NetworkInterface] =
    ## Every interface, with its IPv4 and IPv6 addresses (Windows: the
    ## friendly names, "Ethernet", "Wi-Fi"...).
    result = @[]
    var buf = newSeq[NnIfInfo](64)
    let n = int(nnIfList(addr buf[0], cint(buf.len)))
    var i = 0
    while i < n:
      var ni = NetworkInterface(index: uint32(buf[i].index), mtu: int(buf[i].mtu), addresses: @[])
      var k = 0
      while k < buf[i].name.len and buf[i].name[k] != '\0':
        ni.name.add buf[i].name[k]
        k = k + 1
      var f = 0
      while f <= ord(high(InterfaceFlag)):
        if (buf[i].flags and (1'u32 shl f)) != 0: ni.flags.incl InterfaceFlag(f)
        f = f + 1
      k = 0
      while k < int(buf[i].naddrs):
        let a = buf[i].addrs[k]
        var ip = default(IpAddress)
        if a.family == AF_INET:
          ip = ipv4(a.ip[0], a.ip[1], a.ip[2], a.ip[3])
        else:
          ip = IpAddress(family: ipv6, bytes: a.ip)
        ni.addresses.add InterfaceAddress(ip: ip, prefixLen: int(a.prefix))
        k = k + 1
      result.add ni
      i = i + 1

  proc interfaceByIndex*(index: uint32): NetworkInterface =
    result = NetworkInterface(mtu: -1, addresses: @[])
    for i in interfaces():
      if i.index == index: return i

  proc indexOf*(name: string): uint32 =
    ## The interface index for `name` (0: none), for options that take one.
    result = 0
    for i in interfaces():
      if i.name == name: return i.index

  proc nnIfIsUp(name: cstring): cint {.importc: "nn_if_is_up".}
  proc nnIfSetMtu(name: cstring; mtu: cint): cint {.importc: "nn_if_set_mtu".}
  proc nnIfAddAddr4(name: cstring; ip: ptr byte; prefix: cint; peer: ptr byte): cint {.importc: "nn_if_add_addr4".}

  proc setInterfaceUp*(name: string; up = true): bool =
    ## Windows brings interfaces up by itself (a TUN device once its
    ## session starts): true when `name` is up and `up` asks for that.
    var n = name
    result = up and nnIfIsUp(n.toCString) == 1

  proc setInterfaceMtu*(name: string; mtu: int): bool =
    var n = name
    result = nnIfSetMtu(n.toCString, cint(mtu)) == 0

  proc addAddress4*(name: string; ip: IpAddress; prefixLen: int; peer = any4()): bool =
    ## Add `ip`/`prefixLen`, usable at once; with a `peer`, an on-link
    ## route to it too (a point-to-point link). Needs administrator rights.
    if ip.family != ipv4 or peer.family != ipv4: return false
    var n = name
    var a = ip.bytes
    var p = peer.bytes
    result = nnIfAddAddr4(n.toCString, addr a[0], cint(prefixLen), addr p[0]) == 0

else:
  proc cstr(s: nil cstring): string =
    result = ""
    if s == nil: return
    let p = cast[ptr UncheckedArray[char]](s)
    var i = 0
    while p[i] != '\0':
      result.add p[i]
      i = i + 1

  proc addressFamily(address: pointer): cint {.inline.} =
    # getifaddrs returns sockaddr objects, not eight-byte-aligned storage.
    # Byte access/copy avoids imposing sockaddr_storage's stricter alignment.
    when defined(macosx) or defined(freebsd) or defined(openbsd) or defined(netbsd):
      result = cint(bytesPtr(address)[1])
    else:
      var family = 0'u16
      copyMem(addr family, address, sizeof(family))
      result = cint(family)

  proc prefixOf(mask: nil pointer; v6: bool): int =
    result = 0
    if mask == nil: return
    let p = cast[ptr UncheckedArray[byte]](mask)
    let off = if v6: 8 else: 4
    let n = if v6: 16 else: 4
    var i = 0
    while i < n:
      var b = p[off + i]
      while b != 0:
        result = result + int(b and 1)
        b = b shr 1
      i = i + 1

  proc mtuOf(name: string): int =
    ## SIOCGIFMTU through a throwaway socket.
    result = -1
    let fd = cSocket(AF_INET, SOCK_DGRAM, 0)
    if fd < 0: return
    var req = default(array[64, byte])      # struct ifreq: the name, then a union
    var i = 0
    while i < name.len and i < 15:
      req[i] = byte(name[i])
      i = i + 1
    if cIoctl(fd, culong(SiocGifMtu), addr req[0]) == 0:
      var m: cint = 0
      copyMem(addr m, addr req[16], sizeof(cint))
      result = int(m)
    discard cClose(fd)

  proc interfaces*(): seq[NetworkInterface] =
    ## Every interface, with its IPv4 and IPv6 addresses.
    result = @[]
    var head: IfAddrsList = nil
    if getifaddrs(addr head) != 0 or head == nil: return
    var next: IfAddrsList = head
    while true:
      let p = next
      if p == nil: break
      next = p.ifa_next
      let name = cstr(p.ifa_name)
      var k = -1
      var j = 0
      while j < result.len:
        if result[j].name == name: k = j
        j = j + 1
      if k < 0:
        var ni = NetworkInterface(name: name, mtu: -1, addresses: @[])
        var nm = name
        ni.index = uint32(ifNametoindex(nm.toCString))
        let f = uint32(p.ifa_flags)
        if (f and IffUp) != 0: ni.flags.incl ifUp
        if (f and IffBroadcast) != 0: ni.flags.incl ifBroadcast
        if (f and IffLoopback) != 0: ni.flags.incl ifLoopback
        if (f and IffPointToPoint) != 0: ni.flags.incl ifPointToPoint
        if (f and IffRunning) != 0: ni.flags.incl ifRunning
        if (f and IffMulticast) != 0: ni.flags.incl ifMulticast
        ni.mtu = mtuOf(name)
        result.add ni
        k = result.len - 1
      let a = p.ifa_addr
      if a != nil:
        let fam = addressFamily(a)
        if fam == AF_INET or fam == AF_INET6:
          var sa = default(SockAddrBuf)
          let size = if fam == AF_INET: 16 else: 28
          copyMem(addr sa.ss, a, size)
          sa.len = cuint(size)
          result[k].addresses.add InterfaceAddress(ip: ip(fromRaw(sa)),
                                                   prefixLen: prefixOf(p.ifa_netmask, fam == AF_INET6))
    freeifaddrs(head)

  proc interfaceByIndex*(index: uint32): NetworkInterface =
    result = NetworkInterface(mtu: -1, addresses: @[])
    var buf = default(array[64, char])
    if ifIndextoname(cuint(index), cast[cstring](addr buf[0])) == nil: return
    result = interfaceByName(cstr(cast[cstring](addr buf[0])))

  proc indexOf*(name: string): uint32 =
    ## The interface index for `name` (0: none), for options that take one.
    var n = name
    result = uint32(ifNametoindex(n.toCString))

  # ------------------------------------------------------------ configuring
  # Privileged (root, or CAP_NET_ADMIN on Linux).

  const
    SiocGifFlags = (when defined(linux): 0x8913'u64 else: 0xc0206911'u64)
    SiocSifFlags = (when defined(linux): 0x8914'u64 else: 0x80206910'u64)
    SiocSifMtu = (when defined(linux): 0x8922'u64 else: 0x80206934'u64)
    SiocSifAddr = 0x8916'u64          # Linux
    SiocSifNetmask = 0x891c'u64       # Linux
    SiocSifDstaddr = 0x8918'u64       # Linux
    SiocAifAddr = 0x8040691a'u64      # macOS: struct ifaliasreq

  proc ifreq(name: string): array[64, byte] =
    result = default(array[64, byte])
    var i = 0
    while i < name.len and i < 15:
      result[i] = byte(name[i])
      i = i + 1

  proc withSocket(name: string; req: uint64; r: var array[64, byte]): bool =
    let fd = cSocket(AF_INET, SOCK_DGRAM, 0)
    if fd < 0: return false
    result = cIoctl(fd, culong(req), addr r[0]) == 0
    discard cClose(fd)

  proc setInterfaceUp*(name: string; up = true): bool =
    var r = ifreq(name)
    if not withSocket(name, SiocGifFlags, r): return false
    var flags = uint16(r[16]) or (uint16(r[17]) shl 8)
    flags = if up: flags or uint16(IffUp) else: flags and not uint16(IffUp)
    r[16] = byte(flags and 0xff)
    r[17] = byte(flags shr 8)
    result = withSocket(name, SiocSifFlags, r)

  proc setInterfaceMtu*(name: string; mtu: int): bool =
    var r = ifreq(name)
    var m = cint(mtu)
    copyMem(addr r[16], addr m, sizeof(cint))
    result = withSocket(name, SiocSifMtu, r)

  proc sin4(ip: IpAddress; p: ptr UncheckedArray[byte]) =
    ## A sockaddr_in for `ip` at p (16 bytes, port 0).
    when defined(macosx):
      p[0] = 16
      p[1] = byte(AF_INET)
    else:
      p[0] = byte(AF_INET)
      p[1] = 0
    copyMem(addr p[4], unsafeAddr ip.bytes[0], 4)

  proc maskOf(prefixLen: int): IpAddress =
    result = IpAddress(family: ipv4)
    var left = prefixLen
    var i = 0
    while left > 0 and i < 4:
      result.bytes[i] = if left >= 8: 0xff'u8 else: byte((0xff shl (8 - left)) and 0xff)
      left = left - 8
      i = i + 1

  proc addAddress4*(name: string; ip: IpAddress; prefixLen: int; peer = any4()): bool =
    ## Give interface `name` an IPv4 address (and, for point-to-point links
    ## such as a TUN device, the peer's).
    when defined(linux):
      var r = ifreq(name)
      sin4(ip, cast[ptr UncheckedArray[byte]](addr r[16]))
      if not withSocket(name, SiocSifAddr, r): return false
      r = ifreq(name)
      sin4(maskOf(prefixLen), cast[ptr UncheckedArray[byte]](addr r[16]))
      if not withSocket(name, SiocSifNetmask, r): return false
      if not isUnspecified(peer):
        r = ifreq(name)
        sin4(peer, cast[ptr UncheckedArray[byte]](addr r[16]))
        if not withSocket(name, SiocSifDstaddr, r): return false
      result = true
    elif defined(macosx):
      var r = default(array[64, byte])        # struct ifaliasreq: name, addr, dstaddr/broadaddr, mask
      var i = 0
      while i < name.len and i < 15:
        r[i] = byte(name[i])
        i = i + 1
      sin4(ip, cast[ptr UncheckedArray[byte]](addr r[16]))
      sin4(if isUnspecified(peer): ip else: peer, cast[ptr UncheckedArray[byte]](addr r[32]))
      sin4(maskOf(prefixLen), cast[ptr UncheckedArray[byte]](addr r[48]))
      result = withSocket(name, SiocAifAddr, r)
    else:
      result = false

proc interfaceByName*(name: string): NetworkInterface =
  ## index 0 when there is none.
  result = NetworkInterface(mtu: -1, addresses: @[])
  for i in interfaces():
    if i.name == name: return i
