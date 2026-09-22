## The Nim side of sys/nn_types.h: records the C helpers fill or read,
## declared here with the same layout (tests/tabi.nim checks sizes and
## offsets against the C definitions). Change a type here and in
## nn_types.h together. Public mirrored types (IoVec, MsgHdr, MmsgHdr,
## PollFd, PollEvent) stay in the modules that export them.

type
  NnDinfo* {.bycopy.} = object   ## nn_dinfo: a received datagram's metadata
    dst*: array[16, byte]
    dstFamily*: cint
    ifindex*: cuint
    ttl*: cint
    tos*: cint
    truncated*: cint

when defined(windows):
  type
    NnIfAddr* = object      ## nn_ifaddr
      ip*: array[16, byte]
      family*: cint
      prefix*: cint

    NnIfInfo* = object      ## nn_ifinfo
      index*: cuint
      name*: array[256, char]
      mtu*: cint
      flags*: cuint
      naddrs*: cint
      addrs*: array[32, NnIfAddr]

    Linger* = object        ## struct linger (u_short fields on Windows)
      l_onoff*: uint16
      l_linger*: uint16
else:
  type
    Linger* = object        ## struct linger
      l_onoff*: cint
      l_linger*: cint
