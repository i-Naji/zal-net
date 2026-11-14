## ICMP echo over IPv4 and IPv6 loopbacks; an address nobody answers; a
## name that does not resolve. Skips, passing, where ICMP sockets are not
## allowed.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/net/address
import zal_net/raw/icmp

proc main() {.passive.} =
  let r4 = ping("127.0.0.1", 2000)
  if r4.error == PingDenied:
    echo "SKIP ICMP sockets are not allowed here (net.ipv4.ping_group_range)"
    quit 0
  assert r4.error == 0 and $r4.source == "127.0.0.1", $r4.error
  echo "PASS ping 127.0.0.1: ", r4.latencyUs, " µs, seq ", r4.sequence, ", ttl ", r4.ttl
  let r6 = ping("::1", 2000)
  assert r6.error == 0 or r6.error == PingDenied or r6.error == PingFailed, $r6.error
  echo "PASS ping ::1: ", (if r6.error == 0: $r6.latencyUs & " µs" else: "error " & $r6.error)
  let none = ping("192.0.2.1", 300)
  assert none.error == IoTimedOut or none.error == PingFailed
  echo "PASS an address nobody answers: ", none.error
  assert ping("no-such-host.invalid", 1000).error == PingNoHost
  echo "PASS a name that does not resolve"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
