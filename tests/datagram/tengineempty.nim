{.feature: "assumeSync".}
import std/[assertions, syncio]
import zal_net
import zal_net/datagram
import zal_net/raw/[socket, io]
import zal_net/net/endpoint

proc main() {.passive.} =
  try:
    var target = openUdp(0, "127.0.0.1")
    let engine = newDatagramEngine(maxAssocs = 16)
    assert engine != nil
    startEngine(engine)
    let socket = tryListenUdp(0, "127.0.0.1")
    assert socket.ok
    let listenPort = localPort(socket.fd)
    var destination = default(Endpoint)
    assert parseHost("127.0.0.1", target.port, destination)
    var settings = TunnelTarget(destination: destination)
    let message = addListener(engine, 0, socket.fd, unsafeAddr tunnelCodec, addr settings)
    while not engineMsgDone(message): sleepMs(1)
    assert message.ok
    releaseEngineMsg(message)
    var client = openUdp(0, "127.0.0.1")
    client.connect("127.0.0.1", listenPort)
    var empty = default(array[0, byte])
    var peer = default(SocketAddress)
    client.send(empty, afterMs(2000))
    assert target.recvFrom(empty, peer, afterMs(2000)) == 0
    target.sendTo(empty, peer, afterMs(2000))
    assert client.recv(empty, afterMs(2000)) == 0
    close client
    close target
    releaseEngineMsg(stopEngine(engine))
    while not engineStopped(engine): sleepMs(1)
    assert freeEngine(engine)
    echo "PASS empty datagrams through a tunnel in both directions"
  except ErrorCode:
    assert false

assert runMain(main())
