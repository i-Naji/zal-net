## Idle close retires registry entries; failed admission must not leak a socket.
import std/[assertions, syncio]
import zal_net/rt, zal_net/raw/io
import zal_net/raw/tcp

initRuntime()
for cycle in 0..<256:
  var listener = listenTcp(0, "127.0.0.1")
  assert listener.ok, "idle listener admission"
  let descriptor = nativeHandle(listener)
  assert listenerSlot(descriptor) >= 0
  closeNow(listener)
  assert not listener.ok and listenerSlot(descriptor) == -1
  closeNow(listener)

var owners = default(array[MaxListeners, TcpListener])
for index in 0..<owners.len:
  owners[index] = listenTcp(0, "127.0.0.1")
  assert owners[index].ok, "registry capacity"
var rejected = listenTcp(0, "127.0.0.1")
assert not rejected.ok and rejected.error.len > 0
closeNow(rejected)
for index in 0..<owners.len:
  closeNow(owners[index])
  assert not owners[index].ok
var again = listenTcp(0, "127.0.0.1")
assert again.ok, "capacity restored"
closeNow(again)
requestStop()
drainRuntime()
echo "PASS idle listener reuse and registry saturation"
