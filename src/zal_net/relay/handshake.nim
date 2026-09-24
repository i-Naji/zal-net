## Handshake helpers, inline in the caller's passive frame: buffer exactly
## what a header needs, and send a reply.
import zal_net/rt
import zal_net/raw/io
import zal_net/relay/conn

template fillTo*(c: Conn; d: DirectionPtr; want: int; deadline: Deadline; res: var int; ok: var bool) =
  ## Buffer at least `want` bytes after d.off. Extra bytes stay buffered.
  ## Progress does not extend `deadline`. The arguments are evaluated once
  ## (a template would otherwise re-evaluate `want` on every pass).
  let ftWant = want
  let ftDeadline = deadline
  ok = ensurePayload(d)
  while ok and d.fill - d.off < ftWant:
    let room = BufCap - d.fill
    let n = readSome(d.src, bufAt(d, d.fill), room)
    if n > 0:
      touchIo(addr c.lastIo)
      d.fill = d.fill + n
    elif n == IoAgain:
      parkPoll(d.src, {evRead}, ftDeadline, res)
      if res <= 0:
        ok = false
        break
    else:
      ok = false
      break

template sendAll*(c: Conn; fd: cint; p0: pointer; n0: int; res: var int; ok: var bool) =
  block:
    let saBase = cast[int](p0)
    let saLen = n0
    var sentOff = 0
    ok = true
    while sentOff < saLen:
      let p = cast[pointer](saBase + sentOff)
      let n = writeSome(fd, p, saLen - sentOff)
      if n > 0:
        sentOff = sentOff + n
      elif n == IoAgain:
        parkReady(fd, {evWrite}, addr c.lastIo, c.timeoutMs, res)
        if res <= 0:
          ok = false
          break
      else:
        ok = false
        break
