## Datagram metadata and multicast: a unicast datagram reports its
## destination, interface and TTL; a multicast datagram sent to a joined
## group comes back through multicast loop with the group as destination
## and TTL 1; a reply sent from a chosen source address arrives from it.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/net/address
import zal_net/raw/udp

proc main() {.passive.} =
  var buf = default(array[256, byte])
  let msg = [byte 1, 2, 3, 4]
  var info = default(DatagramInfo)

  var r = bindUdp(0, "127.0.0.1", timeoutMs = 2000)
  assert r.ok and enableInfo(r)
  var s = openUdp()
  assert sendTo(s, msg, localAddress(r)) == 4
  assert recvFrom(r, buf, info) == 4
  assert info.hasDestination and $info.destination == "127.0.0.1", $info.destination
  assert info.interfaceIndex > 0 and info.ttl > 0 and not info.truncated
  echo "PASS unicast metadata: destination ", info.destination, ", interface ", int(info.interfaceIndex),
       ", ttl ", info.ttl, ", tos ", info.tos

  # A reply from a chosen source address.
  var src = default(IpAddress)
  assert parseIp("127.0.0.1", src)
  var from0 = default(SocketAddress)
  let sf = sendWithSource(r, addr msg[0], 4, info.source, src)
  if sf != 4: echo "sendFrom returned ", sf
  assert sf == 4
  assert recvFrom(s, buf, from0) == 4 and $ip(from0) == "127.0.0.1"
  echo "PASS a reply sent from a chosen source address"

  # Multicast through the default interface, looped back to this host.
  var group = default(IpAddress)
  assert parseIp("239.255.42.99", group)
  var m = bindUdp(0, "0.0.0.0", timeoutMs = 1500)
  assert m.ok and enableInfo(m)
  if not joinGroup(m, group):
    echo "SKIP no multicast-capable interface here"
    quit 0
  var sender = bindUdp(0, "0.0.0.0")
  assert setMulticastLoop(sender, true) and setMulticastTtl(sender, 1)
  assert sendTo(sender, msg, initSocketAddress(group, port(localAddress(m)))) == 4
  let n = recvFrom(m, buf, info)
  assert n == 4, $n
  assert $info.destination == "239.255.42.99" and info.ttl == 1, $info.destination & " " & $info.ttl
  assert leaveGroup(m, group) and setBroadcast(sender)
  echo "PASS multicast: joined, looped back with the group as destination and TTL 1; broadcast allowed"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
