## Socket-level constants, socket-address types, and building and parsing
## addresses without the resolver.

when defined(macosx):
  const
    AF_INET* = 2.cint
    AF_INET6* = 30.cint
    SOCK_STREAM* = 1.cint
    SOCK_DGRAM* = 2.cint
    SOL_SOCKET* = 0xffff.cint
    SO_REUSEADDR* = 4.cint
    SO_REUSEPORT* = 0x200.cint
    SO_KEEPALIVE* = 8.cint
    SO_LINGER* = 0x0080.cint
    SO_SNDBUF* = 0x1001.cint
    SO_RCVBUF* = 0x1002.cint
    IPPROTO_TCP* = 6.cint
    TCP_NODELAY* = 1.cint
    IPPROTO_IPV6* = 41.cint
    IPV6_V6ONLY* = 27.cint
    SO_ERROR* = 0x1007.cint
    F_GETFL* = 3.cint
    F_SETFL* = 4.cint
    O_NONBLOCK* = 4.cint
    SHUT_WR* = 1.cint
    AI_PASSIVE* = 1.cint
    AI_V4MAPPED* = 0x800.cint
    AI_ALL* = 0x100.cint
    SIGPIPE* = 13.cint
    SIG_IGN* = 1.cint
    SIGINT* = 2.cint
    SIGTERM* = 15.cint
    EInProgress* = 36
elif defined(windows):
  {.compile: "../private/sys/win/nn_win.c".}
  {.passL: "-lws2_32 -liphlpapi -lntdll -lwinmm".}
  const
    AF_INET* = 2.cint
    AF_INET6* = 23.cint
    SOCK_STREAM* = 1.cint
    SOCK_DGRAM* = 2.cint
    SOL_SOCKET* = 0xffff.cint
    SO_REUSEADDR* = 4.cint
    SO_REUSEPORT* = -1.cint          ## none: SO_REUSEADDR there lets others take the port
    SO_KEEPALIVE* = 8.cint
    SO_LINGER* = 0x0080.cint
    SO_SNDBUF* = 0x1001.cint
    SO_RCVBUF* = 0x1002.cint
    IPPROTO_TCP* = 6.cint
    TCP_NODELAY* = 1.cint
    IPPROTO_IPV6* = 41.cint
    IPV6_V6ONLY* = 27.cint
    SO_ERROR* = 0x1007.cint
    F_GETFL* = 3.cint
    F_SETFL* = 4.cint
    O_NONBLOCK* = 4.cint
    SHUT_WR* = 1.cint
    AI_PASSIVE* = 1.cint
    AI_V4MAPPED* = 0x800.cint
    AI_ALL* = 0x100.cint
    SIGPIPE* = 13.cint
    SIG_IGN* = 1.cint
    SIGINT* = 2.cint
    SIGTERM* = 15.cint
    EInProgress* = 115               ## what sys/win/nn_win.c reports for WSAEWOULDBLOCK on connect
else:
  const
    AF_INET* = 2.cint
    AF_INET6* = 10.cint
    SOCK_STREAM* = 1.cint
    SOCK_DGRAM* = 2.cint
    SOL_SOCKET* = 1.cint
    SO_REUSEADDR* = 2.cint
    SO_REUSEPORT* = 15.cint
    SO_KEEPALIVE* = 9.cint
    SO_LINGER* = 13.cint
    SO_SNDBUF* = 7.cint
    SO_RCVBUF* = 8.cint
    IPPROTO_TCP* = 6.cint
    TCP_NODELAY* = 1.cint
    IPPROTO_IPV6* = 41.cint
    IPV6_V6ONLY* = 26.cint
    SO_ERROR* = 4.cint
    F_GETFL* = 3.cint
    F_SETFL* = 4.cint
    O_NONBLOCK* = 2048.cint
    SHUT_WR* = 1.cint
    AI_PASSIVE* = 1.cint
    AI_V4MAPPED* = 8.cint
    AI_ALL* = 0x10.cint
    SIGPIPE* = 13.cint
    SIG_IGN* = 1.cint
    SIGINT* = 2.cint
    SIGTERM* = 15.cint
    EInProgress* = 115


const
  MaxAddrs* = 4  ## addresses tried per dial

when defined(windows):
  type
    IoVec* = object                  ## struct iovec; nn_win.c turns it into a WSABUF
      iov_base*: nil pointer         # a zeroed iovec is valid C
      iov_len*: csize_t

    SockaddrStorage* {.importc: "struct sockaddr_storage", header: "<winsock2.h>".} = object
      ss_family*: uint16
else:
  type
    IoVec* {.importc: "struct iovec", header: "<sys/uio.h>".} = object
      iov_base*: nil pointer         # a zeroed iovec is valid C
      iov_len*: csize_t

    SockaddrStorage* {.importc: "struct sockaddr_storage", header: "<sys/socket.h>".} = object
      ss_family*: uint16

type
  SockAddrBuf* = object
    ## Any socket address, plain data.
    ss*: SockaddrStorage
    len*: cuint

when defined(windows):
  type
    SockaddrIn6* {.importc: "struct sockaddr_in6", header: "<ws2tcpip.h>".} = object
      sin6_family: uint16
      sin6_port: uint16
      sin6_flowinfo: uint32
      sin6_addr: array[16, byte]
      sin6_scope_id: uint32

    SockaddrIn* {.importc: "struct sockaddr_in", header: "<winsock2.h>".} = object
      sin_family: uint16
      sin_port: uint16
      sin_addr: uint32
      sin_zero: array[8, byte]

    Sockaddr* {.importc: "struct sockaddr", header: "<winsock2.h>".} = object
      sa_family: uint16
      sa_data: array[14, byte]

    AddrInfo* {.importc: "struct addrinfo", header: "<ws2tcpip.h>".} = object
      ai_flags*: cint
      ai_family*: cint
      ai_socktype*: cint
      ai_protocol*: cint
      ai_addrlen*: cuint
      ai_addr*: nil ptr Sockaddr
      ai_canonname*: nil cstring
      ai_next*: nil ptr AddrInfo
    AddrInfoList* = nil ptr AddrInfo   ## getaddrinfo's list, or nil

  proc htons*(x: uint16): uint16 {.inline.} = (x shl 8) or (x shr 8)
  proc inet_pton*(af: cint; src: cstring; dst: pointer): cint {.importc: "nn_inet_pton".}
  proc inetNtop*(af: cint; src: pointer; dst: cstring; size: cuint): cstring {.importc: "nn_inet_ntop".}
  proc getaddrinfo*(node, service: nil cstring; hints: nil ptr AddrInfo; res: ptr AddrInfoList): cint {.importc: "nn_getaddrinfo".}
  proc freeaddrinfo*(res: ptr AddrInfo) {.importc: "nn_freeaddrinfo".}
  proc gai_strerror*(err: cint): cstring {.importc: "nn_gai_strerror".}
else:
  type
    SockaddrIn6* {.importc: "struct sockaddr_in6", header: "<netinet/in.h>".} = object
      sin6_family: uint16
      sin6_port: uint16
      sin6_flowinfo: uint32
      sin6_addr: array[16, byte]
      sin6_scope_id: uint32

    SockaddrIn* {.importc: "struct sockaddr_in", header: "<netinet/in.h>".} = object
      sin_family: uint16
      sin_port: uint16
      sin_addr: uint32
      sin_zero: array[8, byte]

    Sockaddr* {.importc: "struct sockaddr", header: "<sys/socket.h>".} = object
      sa_family: uint16
      sa_data: array[14, byte]

    AddrInfo* {.importc: "struct addrinfo", header: "<netdb.h>".} = object
      ai_flags*: cint
      ai_family*: cint
      ai_socktype*: cint
      ai_protocol*: cint
      ai_addrlen*: cuint
      ai_addr*: nil ptr Sockaddr
      ai_canonname*: nil cstring
      ai_next*: nil ptr AddrInfo
    AddrInfoList* = nil ptr AddrInfo   ## getaddrinfo's list, or nil

  proc htons*(x: uint16): uint16 {.importc, header: "<arpa/inet.h>".}
  proc inet_pton*(af: cint; src: cstring; dst: pointer): cint {.importc, header: "<arpa/inet.h>".}
  proc inetNtop*(af: cint; src: pointer; dst: cstring; size: cuint): cstring {.importc: "inet_ntop", header: "<arpa/inet.h>".}
  proc getaddrinfo*(node, service: nil cstring; hints: nil ptr AddrInfo; res: ptr AddrInfoList): cint {.importc, header: "<netdb.h>".}
  proc freeaddrinfo*(res: ptr AddrInfo) {.importc, header: "<netdb.h>".}
  proc gai_strerror*(err: cint): cstring {.importc, header: "<netdb.h>".}

proc setSaLen*(p: pointer; n: int) =
  ## Darwin sockaddr starts with sa_len. Linux ignores the byte.
  when defined(macosx):
    cast[ptr uint8](p)[] = uint8(n)

proc setIpAddr*(sa: var SockAddrBuf; ip: openArray[byte]; port: uint16; family: cint): bool =
  ## Raw IPv4/IPv6 bytes to a socket address. A 4-byte address on an
  ## AF_INET6 socket becomes the v4-mapped form.
  zeroMem(addr sa.ss, sizeof(sa.ss))
  if ip.len == 4 and family != AF_INET6:
    let a = cast[ptr SockaddrIn](addr sa.ss)
    a.sin_family = uint16(AF_INET)
    a.sin_port = htons(port)
    copyMem(addr a.sin_addr, unsafeAddr ip[0], 4)
    setSaLen(a, sizeof(SockaddrIn))
    sa.len = cuint(sizeof(SockaddrIn))
    return true
  if ip.len != 4 and ip.len != 16: return false
  let a = cast[ptr SockaddrIn6](addr sa.ss)
  a.sin6_family = uint16(AF_INET6)
  a.sin6_port = htons(port)
  let raw = cast[ptr UncheckedArray[byte]](addr sa.ss) # sin6_addr at offset 8
  if ip.len == 4:
    raw[18] = 255
    raw[19] = 255
    copyMem(addr raw[20], unsafeAddr ip[0], 4)
  else:
    copyMem(addr raw[8], unsafeAddr ip[0], 16)
  setSaLen(a, sizeof(SockaddrIn6))
  sa.len = cuint(sizeof(SockaddrIn6))
  result = true

proc setPort*(sa: var SockAddrBuf; port: uint16) =
  ## sin_port and sin6_port both sit at offset 2, in network order.
  let p = cast[ptr UncheckedArray[byte]](addr sa.ss)
  p[2] = byte(port shr 8)
  p[3] = byte(port and 0xff)

proc parseNumeric*(host: string; port: uint16; family: cint; sa: var SockAddrBuf): bool =
  ## inet_pton fast path: numeric hosts never reach the resolver.
  if host.len == 0 or host.len > 45: return false
  var h = host
  var ip = default(array[16, byte])
  if inet_pton(AF_INET, h.toCString, addr ip[0]) == 1:
    return setIpAddr(sa, ip.toOpenArray(0, 3), port, family)
  if inet_pton(AF_INET6, h.toCString, addr ip[0]) == 1:
    if family == AF_INET: return false
    return setIpAddr(sa, ip, port, AF_INET6)
  result = false

