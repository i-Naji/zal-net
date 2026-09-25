## A local shutdown behaves the same on every platform. A write after
## shutWrite fails (EPIPE) without killing the process: Linux and macOS
## raise SIGPIPE for it, which initRuntime ignores (this test never calls
## ignoreSigpipe). A read after shutBoth reads end of stream, as on Linux
## and macOS; Windows reports WSAESHUTDOWN there.
import std/syncio
import zal_net/rt
import zal_net/raw/tcp

proc main() {.passive.} =
  var l = listenTcp(0, "127.0.0.1")
  if not l.ok: quit "FAIL listen"
  var c = connect("127.0.0.1", port(l))
  var s = accept(l)
  if not isOpen(c) or not isOpen(s): quit "FAIL connect"

  shutdown(addr s, shutWrite)
  if write(addr s, "after shutdown"): quit "FAIL a write after shutWrite succeeded"
  echo "PASS a write after shutWrite fails without SIGPIPE"

  # The peer stays open and silent: end of stream can only come from the
  # local shutdown.
  shutdown(addr s, shutBoth)
  var buf = default(array[16, byte])
  let n = recv(addr s, buf)
  if n != 0: quit "FAIL a read after shutBoth returned " & $n & ", not end of stream"
  echo "PASS a read after shutBoth reads end of stream"

  close(addr c)
  close(addr s)
  closeNow(l)
  quit 0

initRuntime()
spawnTask main()
drainRuntime()
