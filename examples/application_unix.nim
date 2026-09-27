## Local byte exchange. Supply a socket path in a directory you own.
import std/[assertions, cmdline, syncio]
import zal_net/rt
import zal_net/net/unix as local

proc main() {.passive.} =
  try:
    if paramCount() != 1:
      echo "usage: application_unix SOCKET_PATH"
    else:
      let server = local.listen(paramStr(1))
      defer: server.close()
      let client = local.connect(server.path, deadline=afterMs(2000))
      defer: client.close()
      let peer = server.accept(deadline=afterMs(2000))
      defer: peer.close()
      var bytes = [31'u8, 73, 42]
      client.write(bytes)
      assert peer.read(bytes, deadline=afterMs(2000)) == bytes.len
      client.shutdownWrite()
      assert peer.read(bytes, deadline=afterMs(2000)) == 0
      echo "PASS local stream exchange"
  except ErrorCode as error:
    echo "local exchange failed: ", error

assert runMain(main())
