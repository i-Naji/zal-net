## Local byte exchange. Supply a socket path in a directory you own.
import std/[assertions, cmdline, syncio]
import zal_net

proc main() {.passive.} =
  try:
    if paramCount() != 1:
      echo "usage: application_unix SOCKET_PATH"
    else:
      var listener = listenUnix(paramStr(1))
      defer: close listener     # removes the socket file
      var client = connectUnix(paramStr(1), afterMs(2000))
      var peer = listener.accept(afterMs(2000))
      var bytes = [31'u8, 73, 42]
      client.write bytes
      assert peer.read(bytes, afterMs(2000)) == bytes.len
      client.shutdownWrite()
      assert peer.read(bytes, afterMs(2000)) == 0
      echo "PASS local stream exchange"
  except ErrorCode as error:
    echo "local exchange failed: ", error

assert runMain(main())
