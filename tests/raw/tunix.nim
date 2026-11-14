## Unix-domain sockets: an echo stream, a stale socket file replaced and a
## live one refused, the file removed on close; datagrams answered to the
## sender's path (not on Windows, which has Unix streams only).
import std/assertions
import std/syncio
import zal_net/rt
import zal_net/raw/io
import zal_net/net/address
import zal_net/raw/unix

import std/envvars
import zal_net/private/sys/sock

proc getpid(): int = getPid()

proc tmpDir(): string =
  when defined(windows): getEnv("TEMP") & "\\"
  else: "/tmp/"

proc echoStream(s: UnixStreamPtr): int {.passive.} =
  var buf = default(array[4096, byte])
  while true:
    let n = recv(s, buf)
    if n <= 0 or not writeAll(s, buf.toOpenArray(0, n - 1)): break
  result = 0

proc echoDgram(u: UnixDatagram) {.passive.} =
  var buf = default(array[256, byte])
  var src = default(SocketAddress)
  let n = recvFrom(u, addr buf[0], buf.len, addr src)
  if n >= 0: discard sendTo(u, addr buf[0], n, src)

proc leave(path: string): bool =
  result = true
  try: writeFile(path, "stale")
  except: result = false

proc main() {.passive.} =
  let path = tmpDir() & "nn-tunix-" & $getpid() & ".sock"
  var first = listenUnix(path)
  assert first.ok, first.error
  assert not listenUnix(path).ok               # live: refused
  closeNow(first)
  assert leave(path)                           # stale: replaced
  var l = listenUnix(path)
  assert l.ok, l.error
  serve(l, echoStream)
  var c = connectUnix(path)
  assert c.isOpen and write(addr c, "hello over unix")
  var got = default(array[15, byte])
  assert readExactly(addr c, got)
  close(addr c)
  assert close(l)
  var f: File
  assert not open(f, path)
  echo "PASS Unix streams: echo, stale file replaced, live refused, file removed"

  when not defined(windows):              # Windows has Unix streams only
    let pa = tmpDir() & "nn-tunix-a-" & $getpid() & ".sock"
    let pb = tmpDir() & "nn-tunix-b-" & $getpid() & ".sock"
    var a = bindUnixDatagram(pa)
    var b = bindUnixDatagram(pb)
    assert a.ok and b.ok
    spawnTask echoDgram(b)
    var msg = "datagram"
    assert sendTo(a, cast[pointer](msg.toCString), msg.len, unixAddress(pb)) == msg.len
    var buf = default(array[64, byte])
    var src = default(SocketAddress)
    assert recvFrom(a, addr buf[0], buf.len, addr src) == msg.len and path(src) == pb
    close(a)
    close(b)
    echo "PASS Unix datagrams answered to the sender's path"

  when defined(linux):
    let name = "@nn-tunix-" & $getpid()
    var al = listenUnix(name)
    assert al.ok, al.error
    assert not listenUnix(name).ok             # the name is taken
    serve(al, echoStream)
    var ac = connectUnix(name)
    assert ac.isOpen and write(addr ac, "hello over unix")
    var agot = default(array[15, byte])
    assert readExactly(addr ac, agot)
    assert path(remoteAddress(ac)) == name
    close(addr ac)
    assert close(al)
    var again = listenUnix(name)               # released with the socket
    assert again.ok
    closeNow(again)
    echo "PASS Linux abstract names: echo, name taken, released on close"
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
