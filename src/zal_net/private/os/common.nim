## What every system's module shares: the poll record, flag values that are
## the same everywhere, and the last error as a plain int.

import std/oserrors

type
  PollFd* = object          ## struct pollfd
    fd*: cint
    events*: int16
    revents*: int16

const
  MsgPeek* = 2.cint    ## MSG_PEEK has this value on the supported socket platforms
  PollIn* = 1'i16
  PollOut* = 4'i16
  EIntr* = 4
  ENoEntry* = 2

proc lastErr*(): int =
  result = cast[int](cast[int32](osLastError()))
