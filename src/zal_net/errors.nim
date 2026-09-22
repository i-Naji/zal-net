## Library errors are outside the native errno range. OS failures remain -errno.
## Read/write results are positive byte counts, zero EOF (or a zero-length
## operation), or one of these negative results. Decode errors without allocating.

type IoFailure* = object
  ## Snapshot of the last operation in one direction. No borrowed storage.
  code*: int
  transferred*: int


const
  NetErrorBase* = -100_000
  StreamEof* = NetErrorBase - 1
  TooLong* = NetErrorBase - 2
  InvalidInput* = NetErrorBase - 3
  ResourceClosed* = NetErrorBase - 4
  ResourceBusy* = NetErrorBase - 5
  QueueFull* = NetErrorBase - 6
  NotSupported* = NetErrorBase - 7
  IoAgain* = NetErrorBase - 8
  AcceptAgain* = NetErrorBase - 9
  AcceptBusy* = NetErrorBase - 10
  AcceptClosed* = NetErrorBase - 11
  NoProgress* = NetErrorBase - 12
  DnsNoAddresses* = NetErrorBase - 13
  DnsErrorBase* = -150_000
  DnsErrorRadius* = 30_000       ## signed native getaddrinfo codes, separate from errno

proc describe*(code: int): string =
  ## Allocate a diagnostic only on demand. Numeric OS errors stay intact;
  ## other packages describe their own reserved ranges and delegate here.
  case code
  of 0: result = "EOF or zero-length operation"
  of StreamEof: result = "end of stream"
  of TooLong: result = "buffer or message limit exceeded"
  of InvalidInput: result = "invalid input"
  of ResourceClosed: result = "resource closed"
  of ResourceBusy: result = "resource busy"
  of QueueFull: result = "queue full"
  of NotSupported: result = "operation not supported"
  of IoAgain: result = "I/O would block"
  of AcceptAgain: result = "accept would block"
  of AcceptBusy: result = "accept resource limit reached"
  of AcceptClosed: result = "listener closed"
  of NoProgress: result = "write made no progress"
  of DnsNoAddresses: result = "resolver returned no usable addresses"
  else:
    if code != DnsErrorBase and code > DnsErrorBase - DnsErrorRadius and code < DnsErrorBase + DnsErrorRadius:
      result = "getaddrinfo error " & $(DnsErrorBase - code)
    elif code > 0: result = $code & " bytes transferred"
    elif code > NetErrorBase: result = "OS error " & $(-code)
    else: result = "library error " & $code
