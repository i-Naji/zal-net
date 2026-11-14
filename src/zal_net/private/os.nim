## The operating system, one module per system. The compiler picks the one
## for the target, so a Linux build never reads the Windows bindings and no
## procedure body switches on the system.
##
## All three export the same names: the socket calls (`sockRead`,
## `sockWritev`, `sockPoll`...), wake pairs, errno values, the descriptor
## limit and anonymous mappings.

when defined(windows):
  import zal_net/private/os/windows
  export windows
elif defined(linux):
  import zal_net/private/os/linux
  export linux
elif defined(macosx):
  import zal_net/private/os/macos
  export macos
else:
  {.error: "zal-net supports Linux, macOS and Windows".}
