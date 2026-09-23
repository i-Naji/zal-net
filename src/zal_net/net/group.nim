## Structured task groups over raw Scope/Task. Task arguments are
## copied plain data. A borrowed pointer target must outlive the complete task,
## including cancellation. Destructors cancel/release; they never wait.
import zal_net/rt/[task, sync, cancel], zal_net/[rt, plain, errors]
import zal_net/private/sharedmem
import std/syncio

type
  GroupObj = object
    scope: nil Scope
  Group* = ref GroupObj
  TaskObj = object
    task: nil Task
  TaskRef* = ref TaskObj
  TaskStartResult* = object
    value*: nil TaskRef
    code*: int
  GroupFn*[A] = proc (tok: CancelToken; argument: A): int {.nimcall, passive.}
  Payload[A] = object
    argument: A

proc `=destroy`(group: var GroupObj) =
  let scope = group.scope
  if scope != nil:
    cancel(scope)
    release(scope)

proc `=destroy`(handle: var TaskObj) = release(handle.task)

proc newGroup*(): Group =
  result = Group()
  result.scope = newScope()

proc rawScope(group: Group): Scope {.inline.} =
  let scope = group.scope
  if scope == nil: quit "uninitialized task group"
  scope

proc rawTask(handle: TaskRef): Task {.inline.} =
  let task = handle.task
  if task == nil: quit "uninitialized task handle"
  task

proc startPayload(group: Group; callback: TaskFn; payload: pointer): TaskStartResult =
  result = default(TaskStartResult)
  let task = startTask(callback, payload, rawScope(group))
  if not admitted(task):
    freeShared(payload)
    release(task)
    result.code = ResourceClosed
  else:
    let handle = TaskRef()
    handle.task = task
    result.value = handle

proc newPayload[A](argument: A): pointer =
  requirePlainData(A)
  let payload = cast[ptr Payload[A]](requireShared(sizeof(Payload[A])))
  payload.argument = argument
  cast[pointer](payload)

proc payloadArgument[A](context: pointer): A {.inline.} =
  cast[ptr Payload[A]](context).argument

proc placement(group: Group): int =
  if stopping(): return ResourceClosed
  result = 0

template start*[A](group: Group; fn: GroupFn[A]; argument: A): TaskStartResult =
  ## fn is a statically named passive proc (CancelToken, A) -> int. The pin
  ## erases the passive ABI when taking a generic proc as a callback value;
  ## this concrete expansion guards that limitation without an unchecked cast.
  block:
    requirePlainData(A)
    let held = group
    var outcome = default(TaskStartResult)
    outcome.code = placement(held)
    if outcome.code == 0:
      proc invoke(task: Task; context: nil pointer): int {.nimcall, passive.} =
        let pointer = context
        if pointer == nil: return InvalidInput
        result = fn(token(task), payloadArgument[A](pointer))
        freeShared(pointer)
      let payload = newPayload(argument)
      outcome = startPayload(held, invoke, payload)
    outcome

proc cancel*(group: Group) = cancel(rawScope(group))
proc token*(group: Group): CancelToken = token(rawScope(group))
proc cancel*(task: TaskRef) = cancel(rawTask(task))
proc finished*(task: TaskRef): bool = finished(rawTask(task))
proc code*(task: TaskRef): int = code(rawTask(task))

template join*(handle: TaskRef; deadline: Deadline = never;
               tok: nil CancelToken = nil): WaitResult =
  block:
    let held = handle
    join(rawTask(held), deadline, tok)

template waitAll*(group: Group; deadline: Deadline = never): WaitResult =
  block:
    let held = group
    waitAll(rawScope(held), deadline)

template close*(group: Group; grace: Deadline = never): WaitResult =
  ## Stops admission, then waits; grace expiry cancels and drains every child.
  block:
    let held = group
    close(rawScope(held), grace)
