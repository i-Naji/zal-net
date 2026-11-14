## Network interfaces: the loopback is listed, up, with 127.0.0.1/8 and
## a positive MTU; lookups by name and index agree.
import std/assertions
import std/syncio
import zal_net/net/address
import zal_net/net/interfaces

var lo = default(NetworkInterface)
for i in interfaces():
  if isLoopback(i): lo = i
assert lo.index > 0 and isUp(lo) and (lo.mtu > 0 or (defined(windows) and lo.mtu == -1)), lo.name
var has127 = false
for a in lo.addresses:
  if $a.ip == "127.0.0.1" and a.prefixLen == 8: has127 = true
assert has127
assert interfaceByName(lo.name).index == lo.index
assert interfaceByIndex(lo.index).name == lo.name
assert indexOf(lo.name) == lo.index and interfaceByName("no-such-if0").index == 0
echo "PASS ", interfaces().len, " interfaces; loopback ", lo.name, " #", int(lo.index), " mtu ", lo.mtu,
     " with 127.0.0.1/8; lookups agree"
