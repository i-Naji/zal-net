## Two independently owned UDP tunnels: :9001 and :9002 -> 127.0.0.1:9000.
## Runs for 30 seconds, then drains both engines and the library-owned workers.
## Start a UDP echo service on :9000 to try the tunnels.
import std/[assertions, syncio]
import zal_net/raw
import zal_net/datagram
import zal_net/net/endpoint, zal_net/raw/socket

proc finishEngine(e: ptr DatagramEngine) {.passive.} =
  let stopped = stopEngine(e)
  while not engineMsgDone(stopped): parkUntil(afterMs(10))
  releaseEngineMsg(stopped)
  while not freeEngine(e): parkUntil(afterMs(10))

proc main() {.passive.} =
  var target = default(TunnelTarget)
  assert parseHostPort("127.0.0.1:9000", target.destination)
  let first = newDatagramEngine(listenerLimit = 1, maxAssocs = 4096)
  let second = newDatagramEngine(listenerLimit = 1, maxAssocs = 4096)
  if first == nil or second == nil:
    if first != nil: discard freeEngine(first)
    if second != nil: discard freeEngine(second)
    requestStop()
    return
  startEngine(first)
  startEngine(second)
  let a = tryListenUdp(9001, bindAddr = "127.0.0.1")
  let b = tryListenUdp(9002, bindAddr = "127.0.0.1")
  if a.ok:
    let added = addListener(first, 1, a.fd, addr tunnelCodec, addr target)
    while not engineMsgDone(added): parkUntil(afterMs(10))
    echo "first tunnel ready: ", added.ok
    releaseEngineMsg(added)
  if b.ok:
    let added = addListener(second, 1, b.fd, addr tunnelCodec, addr target)
    while not engineMsgDone(added): parkUntil(afterMs(10))
    echo "second tunnel ready: ", added.ok
    releaseEngineMsg(added)
  parkUntil(afterMs(30_000))
  finishEngine(first)
  finishEngine(second)
  stopBlockingPool()
  while not joinBlockingPool(): parkUntil(afterMs(10))
  requestStop()

initRuntime()
spawnTask main()
drainRuntime()
