import zal_net/net/resolve
## Addresses: IP parse/format, socket addresses, host:port splitting,
## equality across IPv4-mapped forms, CIDR membership, resolution.
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/net/sockaddr
import zal_net/net/address

proc main() {.passive.} =
  var ip = default(IpAddress)
  assert parseIp("192.0.2.7", ip) and ip.family == ipv4 and $ip == "192.0.2.7"
  assert parseIp("[2001:db8::1]", ip) and ip.family == ipv6 and $ip == "2001:db8::1"
  assert not parseIp("300.1.1.1", ip) and not parseIp("host", ip)
  var mapped = default(IpAddress)
  assert parseIp("::ffff:10.1.2.3", mapped) and isMapped4(mapped) and $unmapped(mapped) == "10.1.2.3"
  assert isLoopback(loopback4()) and isLoopback(loopback6()) and isUnspecified(any6())
  echo "PASS IP addresses: parse, format, mapped, loopback"

  var a = default(SocketAddress)
  assert parseSocketAddress("127.0.0.1:8080", a) and port(a) == 8080 and $a == "127.0.0.1:8080"
  assert parseSocketAddress("[::1]:53", a) and $a == "[::1]:53"
  assert not parseSocketAddress("example.org:80", a)          # numeric only
  var host = ""
  var p = 0'u16
  assert splitHostPort("example.org:443", host, p) and host == "example.org" and p == 443
  assert splitHostPort("[fe80::1]:22", host, p) and host == "fe80::1" and p == 22
  assert not splitHostPort("no-port", host, p) and not splitHostPort("h:70000", host, p)
  var m4 = default(SocketAddress)
  assert parseSocketAddress("[::ffff:127.0.0.1]:9", m4)
  var p4 = default(SocketAddress)
  assert parseSocketAddress("127.0.0.1:9", p4)
  assert m4 == p4 and $m4 == "127.0.0.1:9"
  assert $unixAddress("/tmp/x.sock") == "/tmp/x.sock" and isUnix(unixAddress("/tmp/x.sock"))
  assert not isValid(unixAddress("/tmp/x.sock\0suffix"))
  when defined(linux):
    let binaryName = unixAddress("@binary\0name")
    assert isValid(binaryName) and binaryName.raw.len == 14
    assert $binaryName == "@binary\0name"
  else:
    assert not isValid(unixAddress("@binary\0name"))
  echo "PASS socket addresses: parse, format, split, mapped equality, Unix paths"

  var c = default(Cidr)
  assert parseCidr("10.0.0.0/8", c)
  assert parseIp("10.200.1.1", ip) and ip in c
  assert parseIp("11.0.0.1", ip) and ip notin c
  assert parseIp("::ffff:10.9.9.9", ip) and ip in c                 # mapped matches IPv4
  assert parseCidr("2001:db8::/32", c) and parseIp("2001:db8:ffff::1", ip) and ip in c
  assert not parseCidr("10.0.0.0/33", c)
  echo "PASS CIDR membership, IPv4-mapped included"

  let local = resolve("localhost", 80)
  assert local.len > 0 and isLoopback(ip(local[0])) and port(local[0]) == 80
  assert resolve4("127.0.0.1", 1).len == 1
  assert resolve("no-such-host.invalid", 80).len == 0
  echo "PASS resolve: ", local.len, " address(es) for localhost"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
