## Linux: errno values, flag values and the calls only Linux has.

import zal_net/private/os/common
export common

{.compile: "../sys/nn_linux.c".}       # fallbacks for old kernels (NN_LINUX_COMPAT=1 forces them)

const
  EAgain* = 11
  ENoBufs* = 105
  EConnRefused* = 111
  ENotSocket* = 88
  ONonblock = 2048.cint
  SockCloexec = 0x80000.cint   # SOCK_CLOEXEC, ORed into socket()'s type
  NoFile = 7.cint              # RLIMIT_NOFILE
  MapPrivateAnon = 0x22.cint

proc fdCeiling(): uint64 {.inline.} = high(uint64)
  ## The kernel's own ceiling (fs.nr_open) shows up as EPERM from setrlimit.

include zal_net/private/os/posixcommon

proc sockAbort*(fd: cint): bool =
  ## Disconnect a connected TCP socket now, waking whatever waits on it:
  ## with SO_LINGER 0 set, connecting to AF_UNSPEC resets it. False when the
  ## kernel refuses (a kTLS socket).
  var sa = default(array[16, byte])          # sa_family 0: AF_UNSPEC
  result = sockConnect(fd, addr sa[0], cuint(sa.len)) == 0
  # The reset alone polls as error and hang-up, which epoll readers miss.
  if result: discard sockShutdown(fd, 2)
