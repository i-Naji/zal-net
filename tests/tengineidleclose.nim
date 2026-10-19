import std/[assertions, syncio]
import zal_net/[rt, datagram]
import zal_net/raw/[socket, io]

proc main() {.passive.} =
  for host in ["127.0.0.1", "0.0.0.0", "::1", "::"]:
    let engine = newDatagramEngine(maxAssocs = 16)
    assert engine != nil
    startEngine(engine)
    let socket = tryListenUdp(0, host)
    assert socket.ok
    let m = addListener(engine, 0, socket.fd)
    while not engineMsgDone(m): sleepMs(1)
    assert m.ok
    releaseEngineMsg(m)
    sleepMs(50)
    releaseEngineMsg(stopEngine(engine))
    let deadline = afterMs(3000)
    while not engineStopped(engine) and monoNow() < deadline: sleepMs(1)
    assert engineStopped(engine), "idle engine failed to stop: " & host
    assert freeEngine(engine)
  echo "PASS idle UDP listeners close on IPv4, IPv6 and wildcard binds"

assert runMain(main())
