import std/[assertions, syncio, algorithm]
import zal_net
when defined(benchTls):
  # Build with --path:../zal-tls/src and the AWS-LC flags, and run from the
  # zal-tls checkout: the certificates come from its tests/data.
  import zal_tls as tls
  import zal_tls/secure
  type
    ClientSetup = tls.ClientConfig
    ServerSetup = tls.ServerConfig
  const Protocol = "tls"
else:
  type
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

proc echoPeer(accepted: sink Conn; peer: sink Peer) {.passive.} =
  try:
    var c = accepted
    var buffer = newSeq[byte](Size)
    while true:
      let n = c.read(buffer, afterMs(30000))
      if n == 0: break
      c.write(buffer.toOpenArray(0, n - 1), afterMs(30000))
    c.shutdownWrite()
  except ErrorCode as error: peer.error = error
  setEvent(addr peer.done)

proc acceptPeers(listener: ptr Listener; setup: ServerSetup;
                 peers: sink seq[Peer]; accepted: sink Peer) {.passive.} =
  try:
    for peer in peers:
      var c = accept(listener[], afterMs(30000))
      when defined(benchTls):
        c.secure(setup, afterMs(30000))
      assert trySpawnTask(echoPeer(c, peer))
  except ErrorCode as error: accepted.error = error
  setEvent(addr accepted.done)

proc exchange(port: uint16; setup: ClientSetup; client: sink Client) {.passive.} =
  try:
    var c = connect("127.0.0.1", port, afterMs(30000))
    when defined(benchTls):
      c.secure(setup, "test.example", afterMs(30000))
    var payload = newSeq[byte](Size)
    var reply = newSeq[byte](Size)
    for i in 0..<Size: payload[i] = byte(i mod 251)
    client.samples = newSeq[int64](Rounds)
    setEvent(addr client.ready)
    assert wait(addr client.start, afterMs(30000)) == wrReady
    for round in 0..<Rounds:
      let started = monoNow()
      c.write(payload, afterMs(30000))
      var got = 0
      while got < Size:
        let n = c.read(reply.toOpenArray(got, Size - 1), afterMs(30000))
        assert n > 0
        got += n
      client.samples[round] = int64(monoNow()) - int64(started)
      assert reply == payload
    # Each side half-closes and reads the other's end. A secured Conn that
    # is dropped without shutdownWrite leaves its peer waiting for the end.
    c.shutdownWrite()
    assert c.read(reply, afterMs(30000)) == 0
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
    var listener = listen(0, "127.0.0.1")
    var peers: seq[Peer] = @[]
    var clients: seq[Client] = @[]
    for i in 0..<Connections:
      peers.add Peer()
      clients.add Client()
    let accepted = Peer()
    assert trySpawnTask(acceptPeers(addr listener, serverSetup, peers, accepted))
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
    close listener
    var samples: seq[int64] = @[]
    for client in clients:
      let taken = client.samples
      for sample in taken: samples.add sample
    samples.sort()
    echo "protocol=", Protocol, " workers=", runtimeWorkers(), " connections=", Connections,
         " bytes=", Size, " rounds=", Rounds, " elapsed_ns=", elapsed,
         " p50_ns=", samples[samples.len div 2], " p99_ns=", samples[(samples.len * 99) div 100]
  except ErrorCode as error:
    echo error
    assert false

assert runMain(main())
