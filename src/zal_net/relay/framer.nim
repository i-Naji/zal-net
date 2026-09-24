## Framers: a protocol's records around payloads, opened and sealed in
## place by the relay (`relay/conn`). A framer declares its geometry (the
## head and tail bytes around each record, the largest record, and the
## room it needs before the first payload, head included); the relay lays
## out each direction's buffer so the sink's records are written where the
## payload already is.
import zal_net/relay/conn
export Geometry, FramerObj, Framer, MaxRecord, HeadRoom, MaxSpans, PreCap, Span, InAgain, InFail, InEof
