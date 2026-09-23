## A retained single-assignment result. Values obey the shared plain-data
## restriction. A producer handle owns one explicit native reference; move it
## with takeProducer and release it once. The Slot Ref owns the consumer side.
import zal_net/rt/[sync, cancel], zal_net/[plain, rt]

type
  SlotObj[T] = object
    result: Promise[T]
    initialized: bool
  Slot*[T] = ref SlotObj[T]
  SlotProducer*[T] = object
    raw: nil Oneshot

proc `=destroy`[T](slot: var SlotObj[T]) =
  if slot.initialized:
    abandon(slot.result)
    release(slot.result)

proc newSlot*[T](): Slot[T] =
  requirePlainData(T)
  result = Slot[T]()
  result.result = newPromise[T]()
  release(result.result)             # no initial external producer
  result.initialized = true

proc producer*[T](slot: Slot[T]): SlotProducer[T] =
  requirePlainData(T)
  if not slot.initialized: return default(SlotProducer[T])
  retain(slot.result.raw)
  SlotProducer[T](raw: slot.result.raw)

proc takeProducer*[T](producer: var SlotProducer[T]): SlotProducer[T] =
  result = producer
  producer.raw = nil

proc release*[T](producer: var SlotProducer[T]) =
  let raw = producer.raw
  producer.raw = nil
  if raw != nil: release(raw)

proc fulfil*[T](producer: SlotProducer[T]; value: T): bool =
  requirePlainData(T)
  let raw = producer.raw
  if raw == nil: return false
  var copied = value
  result = publish(raw, addr copied, sizeof(T))

proc fulfil*[T](slot: Slot[T]; value: T): bool =
  requirePlainData(T)
  if not slot.initialized: return false
  fulfil(slot.result, value)

proc close*[T](slot: Slot[T]) =
  if slot.initialized: abandon(slot.result)

proc initialized[T](slot: Slot[T]): bool = slot.initialized

proc rawPromise[T](slot: Slot[T]): Promise[T] {.inline.} = slot.result

template wait*[T](slot: Slot[T]; deadline: Deadline = never;
                  tok: nil CancelToken = nil): Received[T] =
  block:
    requirePlainData(T)
    let held = slot
    var received = default(Received[T])
    if not initialized(held): received.res = wrClosed
    else: received = wait(rawPromise(held), deadline, tok)
    received
