## The framed TCP relay: connection blocks with one flat pump per
## direction, framers opened and sealed in place, handshake helpers and
## the accept loop. For protocols that need speed; streams (`net/stream`)
## are the simple way.
import zal_net/relay/conn
import zal_net/relay/framer
import zal_net/relay/handshake
import zal_net/relay/accept
export conn, framer, handshake, accept
