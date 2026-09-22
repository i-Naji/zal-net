## Native resolver failures have their own signed domain; EAI_SYSTEM uses errno.
import zal_net/errors
{.compile: "nn_dns.c".}
proc systemError(code: cint): cint {.importc: "nn_gai_system_error".}

proc resolverFailure*(code: cint): int =
  let native = systemError(code)
  if native != 0: return -int(native)
  let value = int(code)
  if value == 0 or value <= -DnsErrorRadius or value >= DnsErrorRadius:
    return DnsNoAddresses
  result = DnsErrorBase - value
