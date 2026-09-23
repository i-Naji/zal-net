## Pure received-datagram values; importing this module starts no runtime.
import zal_net/net/address

type
  DatagramInfo* = object
    ## What `recvFrom(u, p, n, addr info)` learns about a datagram (after
    ## `enableInfo`): unknown fields stay 0 / -1.
    source*: SocketAddress
    destination*: IpAddress       ## the address it was sent to (multicast groups too)
    hasDestination*: bool
    interfaceIndex*: uint32       ## where it arrived
    ttl*: int                     ## TTL or hop limit, -1 unknown
    tos*: int                     ## TOS byte or traffic class, -1 unknown
    truncated*: bool              ## longer than the buffer
