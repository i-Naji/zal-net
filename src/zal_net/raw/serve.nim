## Contextual serving on a retained listener.
## The handler is a statically known void passive proc, called as
## handler(connection, context). Shared context state must be synchronized.
## Each accepted connection belongs to its handler invocation: the dispatcher
## retains and closes it when the handler returns. Any retained reference then
## observes a closed owner. Listener close ends acceptance; handlers already
## admitted keep running and must be drained by the application's root.
import zal_net/[rt, errors], zal_net/raw/io
import zal_net/raw/tcp, zal_net/foundation/tcp, zal_net/foundation/tcplistener

type ContextHandler*[C] = proc (connection: TcpConnRef; context: C) {.nimcall, passive.}

proc dispatch[C](connection: sink TcpConnRef; context: sink C;
                 handler: ContextHandler[C]) {.passive.} =
  handler(connection, context)
  discard close(connection)

template serve*[C](listener: TcpListenerRef; handler: ContextHandler[C]; ctx: C;
                   streamTimeoutMs = DefaultTimeoutMs; noDelay = true): int =
  block:
    when not (C is ref):
      {.error: "serve context must be a ref object".}
    let held = listener
    let context = ctx
    let callback = handler
    var code = 0
    var burst = 0
    while true:
      let accepted = acceptConn(held, streamTimeoutMs, noDelay)
      if accepted.code != 0:
        code = accepted.code
        break
      let connection = accepted.value
      if connection == nil:
        code = ResourceClosed
        break
      if not trySpawnTask(dispatch(connection, context, callback)):
        discard close(connection)
        code = ResourceClosed
        break
      burst += 1
      if burst >= AcceptBurst:
        # A readable backlog must not starve handlers queued on this loop.
        yieldNow()
        burst = 0
    code
