## Explicit manual-owner foundation for protocol libraries.
## Borrow address-stable owners through pointers; numeric results preserve
## native failures. Relay/datagram engines and platform facilities stay explicit.
## Do not combine this import unqualified with application owner names.
import zal_net/rt
import zal_net/rt/time
import zal_net/rt/cancel
import zal_net/rt/sync
import zal_net/rt/task
import zal_net/rt/blocking
import zal_net/rt/ticker
import zal_net/net/resolve
import zal_net/net/address
import zal_net/raw/tcp
import zal_net/raw/udp
import zal_net/raw/unix
import zal_net/net/stream
import zal_net/net/options

export rt, time, cancel, sync, task, blocking, ticker
export resolve, address, tcp, udp, unix, stream, options
