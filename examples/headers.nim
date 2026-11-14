## A bounded HTTP-style header reader over a `Conn`, plain or with TLS.
## Build with --path:src for TCP; add -d:withTls, --path:../zal-tls/src and
## the AWS-LC flags for TLS. It reads one header block and stops there.
import std/[cmdline, syncio]
import zal_net
when defined(withTls):
  import zal_tls as tls
  import zal_tls/secure

const MaxHead = 8192

proc headLength(bytes: openArray[byte]): int =
  ## The head's length with its blank line, or -1 while the blank line has
  ## not arrived.
  result = -1
  for i in 3 ..< bytes.len:
    if bytes[i-3] == 13 and bytes[i-2] == 10 and bytes[i-1] == 13 and bytes[i] == 10:
      return i + 1

proc takeHead(c: var Conn): string =
  ## The head if it is buffered whole, consumed; "" otherwise. Body bytes stay
  ## in the buffer for whoever reads next.
  result = ""
  let size = headLength(c.peek)
  if size > 0:
    for i in 0 ..< size: result.add char(c.peek[i])
    c.consume size

proc readHead*(c: var Conn; deadline: Deadline): string {.passive, raises.} =
  ## The header block, blank line included. Raises `ContentTooLong` past
  ## `MaxHead` bytes and `EndOfStreamError` when the peer ends first.
  result = takeHead(c)
  while result.len == 0:
    if c.buffered >= MaxHead: raise ContentTooLong
    if c.fill(deadline) == 0: raise EndOfStreamError
    result = takeHead(c)

when isMainModule:
  proc main(host: string) {.passive.} =
    try:
      when defined(withTls):
        let config = tls.newClientConfig(tls.systemTrust())
        var c = connect(host, 443, afterMs(5000))
        c.secure(config, host, afterMs(5000))
      else:
        var c = connect(host, 80, afterMs(5000))
      c.renew afterMs(5000)
      # A fixed request: the host name never reaches the bytes on the wire.
      c.write "GET / HTTP/1.0\r\n\r\n"
      let head = readHead(c, afterMs(5000))
      echo "header bytes=", head.len
    except ErrorCode as error:
      echo error
  if paramCount() != 1: quit "usage: headers hostname"
  discard runMain(main(paramStr(1)))
