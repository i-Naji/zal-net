## Protocol-neutral stream concepts. No concrete TCP or Unix socket dependencies.
import zal_net/rt/[time, cancel]
export time, cancel

type
  ByteStream* = concept
    ## Reads and writes with the stream's own results: >0 bytes, 0 end of
    ## stream (reads), <0 an error or IoTimedOut. Either may move fewer
    ## bytes than asked.
    proc recvInto(s: Self; p: pointer; n: int; deadline: Deadline): int {.passive.}
    proc sendFrom(s: Self; p: pointer; n: int; deadline: Deadline): int {.passive.}

  DuplexStream* = concept
    ## A ByteStream that can end its sending side alone (the peer reads
    ## end of stream, reading goes on) and be interrupted: whatever is
    ## parked on it wakes and fails.
    proc recvInto(s: Self; p: pointer; n: int; deadline: Deadline): int {.passive.}
    proc sendFrom(s: Self; p: pointer; n: int; deadline: Deadline): int {.passive.}
    proc shutdownWrite(s: Self)
    proc interrupt(s: Self)

  CancellableByteStream* = concept
    ## Token-aware custom streams keep their owner usable after a cancelled
    ## wait. A copy/relay with a token rejects unsupported streams before I/O.
    proc recvInto(s: Self; p: pointer; n: int; deadline: Deadline;
                  tok: nil CancelToken): int {.passive.}
    proc sendFrom(s: Self; p: pointer; n: int; deadline: Deadline;
                  tok: nil CancelToken): int {.passive.}
