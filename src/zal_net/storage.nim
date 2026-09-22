## Typed access to caller-defined plain state inside fixed, aligned storage.
## Storage owns no managed values: callers must release resources explicitly.

type AlignmentProbe[T] = object
  prefix: byte
  value: T

proc storageAs*[T, I](words: var array[I, uint64]; stateType: typedesc[T]): ptr T {.inline.} =
  ## The returned pointer borrows words. T must be plain data with an all-zero
  ## empty state. Do not retain the pointer if the owner may move its storage.
  ## Nimony does not expose alignof: a leading byte plus a value makes the
  ## structure's size minus sizeof(T) equal to T's ABI alignment.
  when sizeof(T) > sizeof(words):
    {.error: "extension state exceeds storage size".}
  when sizeof(AlignmentProbe[T]) - sizeof(T) >
       sizeof(AlignmentProbe[uint64]) - sizeof(uint64):
    {.error: "extension state exceeds storage alignment".}
  result = cast[ptr T](addr words[0])
