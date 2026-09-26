## Endpoint views remain allocation-free and independent of any runtime import.
import std/[assertions, syncio]
import zal_net/net/[endpoint, sockaddr]
import zal_net/codecs/socksaddr
import zal_net/buffers

var owned = default(Endpoint)
assert setName(owned, "example.test", 443)
let borrowed = endpointView(owned)
assert valid(borrowed)
assert borrowed.data == bytesPtr(addr owned.host[0])
var copy = default(Endpoint)
assert toEndpoint(borrowed, copy)
owned.host[0] = 'E'
assert hostString(copy) == "example.test"
var encoded = default(array[300, byte])
assert encodeSocksAddr(borrowed, arrayBytes(encoded), 4) == 0
let count = encodeSocksAddr(borrowed, arrayBytes(encoded), encoded.len)
assert count == 16
var wire = default(SocksAddrView)
assert viewSocksAddr(arrayBytes(encoded), 0, count, wire)
let decoded = endpointView(arrayBytes(encoded), wire)
assert toEndpoint(decoded, copy)
assert formatEndpoint(copy) == "Example.test:443"
var invalid = borrowed
invalid.len = 256
assert not valid(invalid)
assert not toEndpoint(invalid, copy) and not valid(copy)
invalid = borrowed
invalid.data = nil
assert not valid(invalid)
owned.host[1] = '\0'
assert not valid(endpointView(owned))
var socket = default(SockAddrBuf)
assert parseNumeric("127.0.0.1", 9000, AF_INET6, socket)
let peer = socketEndpointView(addr socket.ss, socket.len)
assert peer.kind == epIp4 and peer.len == 4 and peer.port == 9000
assert toEndpoint(peer, copy) and formatEndpoint(copy) == "127.0.0.1:9000"
assert not valid(socketEndpointView(addr socket.ss, 1))
assert offsetOrNil(nil, 1) == nil
assert offsetOrNil(addr encoded[0], 2) == addr encoded[2]
echo "PASS endpoint views: borrowing, copying, bounds, codec and mapped IPv4"
