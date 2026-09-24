## The datagram relay engine: one thread carries every UDP listener, with
## batched I/O, GSO/GRO, associations, direct and framed legs, and DNS off
## the thread. Protocols plug in listener codecs and leg kinds; a
## framework plugs in routing and accounting through EngineHooks.
import zal_net/datagram/engine
export engine
