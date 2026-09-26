type
  Hook* = object
    fn*: nil proc (data: ptr int): int {.nimcall.}
proc first*(data: ptr int): int {.nimcall.} = data[]
