## A bounded HTTP-style header reader, reusable over TCP or TLS.
## Build normally for TCP; add -d:withTls and --path:../nimony-tls/src for TLS.
## This example only reads a header block; it is not an HTTP implementation.
import std/[cmdline, syncio]
import zal_net/rt
import zal_net/net/[transport, tcpview]
import zal_net/foundation/tcp
import zal_net/io
when defined(withTls):
  import nimony_tls as tls
  import nimony_tls/net/tlsview

const MaxHead = 8192

type Head* = object
  bytes*: array[MaxHead, byte]
  length*: int
  error*: int

proc readHead*(transport: Transport; deadline: Deadline): Head {.passive.} =
  result = default(Head)
  while result.length < MaxHead:
    # A byte at a time makes the example's boundary explicit: never consume
    # bytes from the body. Production parsers can use zal_net/reader.
    var one = [0'u8]
    let count = recvInto(transport, one, deadline)
    if count <= 0:
      result.error = if count < 0: count else: StreamEof
      return
    result.bytes[result.length] = one[0]
    inc result.length
    let at = result.length
    if at >= 4 and result.bytes[at-4] == 13 and result.bytes[at-3] == 10 and
        result.bytes[at-2] == 13 and result.bytes[at-1] == 10:
      return
  result.error = TooLong

proc exchange(transport: Transport): Head {.passive.} =
  # Fixed input avoids interpolating an untrusted hostname into a request.
  let request = [71'u8,69,84,32,47,32,72,84,84,80,47,49,46,48,13,10,13,10]
  let sent = writeAll(transport, request, afterMs(5000))
  if sent.error != 0:
    result = default(Head)
    result.error = sent.error
  else:
    result = readHead(transport, afterMs(5000))

when isMainModule:
  proc main() {.passive.} =
    let host = paramStr(1)
    when defined(withTls):
      try:
        let config = tls.newClientConfig(tls.systemTrust())
        let connection = tls.connect(config, host, 443, deadline=afterMs(5000))
        defer: connection.close()
        let stream = tlsTransport(connection)
        let head = exchange(stream)
        echo "header bytes=", head.length, " error=", head.error
      except ErrorCode as error:
        echo error
    else:
      let connected = connectTcpConn(host, 80, deadline=afterMs(5000))
      let connection = connected.value
      if connection != nil:
        let stream = tcpTransport(connection)
        defer: discard close(stream)
        let head = exchange(stream)
        echo "header bytes=", head.length, " error=", head.error
  if paramCount() != 1: quit "usage: headers hostname"
  discard runMain(main())
