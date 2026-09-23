## Application errors use Nimony's value-valued ErrorCode raises. Raw I/O
## continues to return its original integer code. No exception object is made.
import zal_net/errors
from zal_net/rt/time import IoTimedOut, ECancelled
when not defined(windows):
  from std/errorcodes/errorcodes_posix import posixToErrorCode

export errors.IoFailure

proc errorKind*(code: int): ErrorCode =
  ## Classify a raw failure without discarding the original code at its owner.
  case code
  of 0: result = Success
  of IoTimedOut: result = TimeoutError
  of ECancelled: result = AbortedOperation
  of InvalidInput: result = ValueError
  of ResourceClosed, AcceptClosed: result = DeadResource
  of ResourceBusy, AcceptBusy: result = BusyError
  of QueueFull: result = FullError
  of NotSupported: result = UnimplementedOperation
  of TooLong: result = ContentTooLong
  of StreamEof: result = EndOfStreamError
  of NoProgress: result = Disconnected
  of IoAgain, AcceptAgain: result = RetryError
  of DnsNoAddresses: result = NameNotFound
  else:
    if code > 0:
      result = Success
    elif code > DnsErrorBase - DnsErrorRadius and code < DnsErrorBase + DnsErrorRadius:
      result = NameNotFound
    elif code > NetErrorBase:
      when defined(windows):
        # The Windows socket shim reports Linux errno values, not WSA codes
        # or the Windows CRT errno constants.
        case code
        of -1, -13: result = PermissionDenied
        of -4: result = InterruptedError
        of -9: result = BadDescriptor
        of -11: result = RetryError
        of -12: result = OutOfMemError
        of -22: result = ValueError
        of -24: result = DescriptorExhaustedError
        of -32, -104, -107: result = Disconnected
        of -90: result = ContentTooLong
        of -95: result = BadOperation
        of -97: result = AddressFamilyUnsupported
        of -98, -106: result = AlreadyConnected
        of -99: result = AddressNotAvailable
        of -100, -101, -113: result = UnreachableHost
        of -105: result = FullError
        of -111: result = RefusedConnection
        of -114, -115: result = AlreadyInProgress
        else: result = IOError
      else:
        result = posixToErrorCode(int32(-code))
        if result == Success:
          result = IOError
    else:
      result = IOError

proc failIo*(code: int) {.raises, noreturn.} =
  let kind = errorKind(code)
  if kind == Success:
    raise Failure
  raise kind

proc checkIo*(code: int) {.raises.} =
  ## A regular procedure: forwarding it adds no passive frame.
  if code < 0:
    failIo(code)
