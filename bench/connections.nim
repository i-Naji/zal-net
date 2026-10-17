import std/[assertions, syncio, algorithm]
import zal_net/rt, zal_net/rt/sync
import zal_net/net/tcp as tcp
when defined(benchTls):
  import zal_tls as tls
  type
    Connection = tls.TlsStream
    ClientSetup = tls.ClientConfig
    ServerSetup = tls.ServerConfig
  const Protocol = "tls"
else:
  type
    Connection = tcp.TcpStream
    ClientSetup = bool
    ServerSetup = bool
  const Protocol = "tcp"

const
  Connections {.intdefine.} = 32
  Rounds {.intdefine.} = 256
  Size {.intdefine.} = 64

when Connections <= 0 or Rounds <= 0 or Size <= 0:
  {.error: "Connections, Rounds and Size must be positive".}

type
  Peer = ref object
    done: Event
    error: ErrorCode
  Client = ref object
    ready, start, done: Event
    error: ErrorCode
    samples: seq[int64]

proc echoPeer(stream: sink Connection; peer: sink Peer) {.passive.} =
  try:
    defer: stream.close()
    var buffer = newSeq[byte](Size)
    while true:
      let n = stream.read(buffer, deadline=afterMs(30000))
      if n == 0: break
      stream.write(buffer.toOpenArray(0, n - 1), deadline=afterMs(30000))
  except ErrorCode as error: peer.error = error
  setEvent(addr peer.done)

proc acceptPeers(listener: sink tcp.TcpListener; setup: ServerSetup;
                 peers: sink seq[Peer]; accepted: sink Peer) {.passive.} =
  try:
    for peer in peers:
      when defined(benchTls):
        var socket: nil tcp.TcpStream = listener.accept(deadline=afterMs(30000))
        let stream = tls.wrapOwned(setup, socket, deadline=afterMs(30000))
      else:
        let stream = listener.accept(deadline=afterMs(30000))
      assert trySpawnTask(echoPeer(stream, peer))
  except ErrorCode as error: accepted.error = error
  setEvent(addr accepted.done)

proc exchange(port: uint16; setup: ClientSetup; client: sink Client) {.passive.} =
  try:
    when defined(benchTls):
      let stream = tls.connect(setup, "127.0.0.1", port,
                               serverName="test.example", deadline=afterMs(30000))
    else:
      let stream = tcp.connect("127.0.0.1", port, deadline=afterMs(30000))
    defer: stream.close()
    var payload = newSeq[byte](Size)
    var reply = newSeq[byte](Size)
    for i in 0..<Size: payload[i] = byte(i mod 251)
    client.samples = newSeq[int64](Rounds)
    setEvent(addr client.ready)
    assert wait(addr client.start, afterMs(30000)) == wrReady
    for round in 0..<Rounds:
      let started = monoNow()
      stream.write(payload, deadline=afterMs(30000))
      var got = 0
      while got < Size:
        let n = stream.read(reply.toOpenArray(got, Size - 1), deadline=afterMs(30000))
        assert n > 0
        got += n
      client.samples[round] = int64(monoNow()) - int64(started)
      assert reply == payload
  except ErrorCode as error: client.error = error
  setEvent(addr client.ready)
  setEvent(addr client.done)

when defined(benchTls):
  proc text(path: string): string =
    try: result = readFile(path)
    except: quit "missing TLS fixture: " & path

proc main() {.passive.} =
  try:
    when defined(benchTls):
      let clientSetup = tls.newClientConfig(tls.pemTrust(text("tests/data/root.pem")))
      let serverSetup = tls.newServerConfig(text("tests/data/leaf.pem") & text("tests/data/inter.pem"),
                                            text("tests/data/leaf.key"))
    else:
      let clientSetup = false
      let serverSetup = false
    let listener = tcp.listen(0, "127.0.0.1")
    defer: listener.close()
    var peers: seq[Peer] = @[]
    var clients: seq[Client] = @[]
    for i in 0..<Connections:
      peers.add Peer()
      clients.add Client()
    let accepted = Peer()
    assert trySpawnTask(acceptPeers(listener, serverSetup, peers, accepted))
    for client in clients:
      assert trySpawnTask(exchange(listener.port, clientSetup, client))
    for client in clients:
      assert wait(addr client.ready, afterMs(30000)) == wrReady
      assert client.error == Success
    let started = monoNow()
    for client in clients: setEvent(addr client.start)
    for client in clients:
      assert wait(addr client.done, afterMs(30000)) == wrReady
      assert client.error == Success
    let elapsed = int64(monoNow()) - int64(started)
    for peer in peers:
      assert wait(addr peer.done, afterMs(30000)) == wrReady
      assert peer.error == Success
    assert wait(addr accepted.done, afterMs(30000)) == wrReady
    assert accepted.error == Success
    var samples: seq[int64] = @[]
    for client in clients:
      for sample in client.samples: samples.add sample
    samples.sort()
    echo "protocol=", Protocol, " workers=", runtimeWorkers(), " connections=", Connections,
         " bytes=", Size, " rounds=", Rounds, " elapsed_ns=", elapsed,
         " p50_ns=", samples[samples.len div 2], " p99_ns=", samples[(samples.len * 99) div 100]
  except ErrorCode as error:
    echo error
    assert false

assert runMain(main())
