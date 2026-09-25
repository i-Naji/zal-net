## Descriptor ownership storage. Zero initialization is always closed, including
## when descriptor zero is a valid socket. No destructor: close may need a loop.
type SocketOwner* = object
  encoded: int64

proc ownedSocket*(fd: cint): SocketOwner {.inline.} =
  ## Internal adoption. The caller relinquishes its descriptor on success.
  result = SocketOwner(encoded: (if fd >= 0: int64(fd) + 1 else: 0))

proc handle*(s: SocketOwner): cint {.inline.} = cint(s.encoded - 1)

proc takeHandle*(s: var SocketOwner): cint {.inline.} =
  result = handle(s)
  s.encoded = 0
