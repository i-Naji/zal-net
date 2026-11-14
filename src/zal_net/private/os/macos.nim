## macOS: errno values, flag values and the calls only Darwin has.

import zal_net/private/os/common
export common

const
  EAgain* = 35
  ENoBufs* = 55
  EConnRefused* = 61
  ENotSocket* = 38
  ONonblock = 4.cint
  NoFile = 8.cint              # RLIMIT_NOFILE
  MapPrivateAnon = 0x1002.cint

proc sysctlbyname(name: cstring; oldp: pointer; oldlenp: ptr csize_t;
                  newp: nil pointer; newlen: csize_t): cint {.importc, header: "<sys/sysctl.h>".}

proc fdCeiling(): uint64 =
  ## kern.maxfilesperproc: setrlimit refuses anything above it.
  var perProc: cint = 0
  var size = csize_t(sizeof(perProc))
  result = high(uint64)
  if sysctlbyname("kern.maxfilesperproc", addr perProc, addr size, nil, 0) == 0 and perProc > 0:
    result = uint64(perProc)

include zal_net/private/os/posixcommon

proc cDisconnectx(fd: cint; aid: uint32; cid: uint32): cint {.importc: "disconnectx", header: "<sys/socket.h>".}

proc sockAbort*(fd: cint): bool =
  ## Disconnect a connected TCP socket now, waking whatever waits on it:
  ## with SO_LINGER 0 set, disconnectx resets it.
  result = cDisconnectx(fd, 0'u32, 0'u32) == 0   # SAE_ASSOCID_ANY, SAE_CONNID_ANY
