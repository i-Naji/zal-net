## Borrowed byte storage. These helpers allocate nothing and never transfer ownership.
## A view is valid only while its owner remains alive and its storage is not resized.

type
  BytesPtr* = ptr UncheckedArray[byte]
  ByteView* = object
    ## Read-only by contract. A nil pointer is valid only when len is zero.
    data*: nil BytesPtr
    len*: int

var emptyByte: array[1, byte]

proc bytesPtr*(p: pointer): BytesPtr {.inline.} =
  ## View an existing non-nil address as bytes; the caller supplies its bounds.
  cast[BytesPtr](p)

proc offset*(p: BytesPtr; n: int): BytesPtr {.inline.} =
  ## Address within the same allocation (including its one-past-end address).
  cast[BytesPtr](addr p[n])

proc arrayBytes*[I](a: var array[I, byte]): BytesPtr {.inline.} =
  ## A generic proc rather than an untyped cast template (compiler repro c36).
  when a.len > 0:
    result = cast[BytesPtr](addr a[0])
  else:
    result = cast[BytesPtr](addr emptyByte[0])

proc dataPtr*(a: openArray[byte]): pointer {.inline.} =
  ## Borrow for reading. Empty arrays have a valid sentinel address, length zero.
  ## Never write through a view of immutable storage.
  if a.len == 0: result = addr emptyByte[0]
  else: result = cast[pointer](unsafeAddr a[0])

proc view*(a: openArray[byte]): ByteView {.inline.} =
  ByteView(data: bytesPtr(dataPtr(a)), len: a.len)

proc mutableWindow*(buffer: var openArray[byte]): openArray[byte] {.inline, establishesBorrow.} =
  ## Borrow writable bytes; keep the source alive without resizing it.
  buffer

proc offsetOrNil*(p: nil pointer; n: int): nil pointer {.inline.} =
  ## FFI buffers such as iovec permit nil. Preserve it; a non-nil address must
  ## still point within the caller's live allocation after advancing by n.
  if p == nil: result = nil
  else: result = offset(bytesPtr(p), n)
