## Process-owned services stop and join before the standard pool shuts down.
import std/[atomics, ticketlocks]

type
  ServiceHooks = object
    stop: nil proc () {.nimcall.}
    join: nil proc (): bool {.nimcall.}
  ServiceRegistry = ref object
    lock: TicketLock
    closing: int
    count: int
    hooks: array[16, ServiceHooks]
    stopped, joined: array[16, bool]
let registry = ServiceRegistry()

proc closeServiceAdmission*() = atomicStore(registry.closing, 1, moRelease)

proc registerProcessService*(stop: nil proc () {.nimcall.}; join: nil proc (): bool {.nimcall.}): bool =
  if stop == nil or join == nil: return false
  acquire(registry.lock)
  defer: release(registry.lock)
  if atomicLoad(registry.closing, moAcquire) != 0 or registry.count == registry.hooks.len:
    return false
  registry.hooks[registry.count] = ServiceHooks(stop: stop, join: join)
  inc registry.count
  result = true

proc joinProcessServices*(): bool =
  # Entry-thread only. Registration is closed before this snapshot.
  acquire(registry.lock)
  let count = registry.count
  release(registry.lock)
  result = true
  for index in 0..<count:
    if not registry.stopped[index]:
      let stop = registry.hooks[index].stop
      if stop != nil: stop()
      registry.stopped[index] = true
    if not registry.joined[index]:
      let join = registry.hooks[index].join
      registry.joined[index] = join != nil and join()
    if not registry.joined[index]: result = false
