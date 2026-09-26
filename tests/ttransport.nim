## Retained transport: owner lifetime, shared invalidation, results and drains.
import std/[assertions, syncio]
import zal_net/[rt, io]
import zal_net/net/transport
import zal_net/rt/sync
import ../examples/headers

var destroyed, closes: int
var writeStarted, writeContinue, writeDone: Event
type MemoryObj = object
  bytes: seq[byte]
  at: int
  blocked, pauseWrites: bool
  writes: int
  done: Event
type Memory = ref MemoryObj
proc `=destroy`(memory: var MemoryObj) = inc destroyed

proc readMemory(ctx: pointer; p: pointer; n: int; until: Deadline;
                tok: nil CancelToken): int {.passive.} =
  let memory = cast[Memory](ctx)
  if memory.blocked:
    discard wait(addr memory.done, until, tok)
    return ResourceClosed
  result = min(n, memory.bytes.len - memory.at)
  if result > 0:
    copyMem(p, addr memory.bytes[memory.at], result)
    memory.at += result
proc writeMemory(ctx: pointer; p: pointer; n: int; until: Deadline;
                 tok: nil CancelToken): int {.passive.} =
  let memory = cast[Memory](ctx)
  inc memory.writes
  if memory.pauseWrites and memory.writes == 2:
    setEvent(addr writeStarted)
    assert wait(addr writeContinue, until, tok) == wrReady
  let bytes = cast[ptr UncheckedArray[byte]](p)
  result = min(n, 3)
  for i in 0..<result: memory.bytes.add bytes[i]
proc halfClose(ctx: pointer) = discard
proc interruptMemory(ctx: pointer) =
  let memory = cast[Memory](ctx)
  setEvent(addr memory.done)
proc disposeMemory(ctx: pointer): int =
  inc closes
  result = 0
proc closeMemory(ctx: pointer): int {.passive.} =
  result = disposeMemory(ctx)
proc transferMemory(ctx: pointer): int = 0

proc createMemory(blocked = false; pauseWrites = false): Transport =
  let memory = Memory(blocked: blocked, pauseWrites: pauseWrites)
  result = retainTransport(memory,
    StreamOps(recv: readMemory, send: writeMemory,
      shutdownWrite: halfClose, interrupt: interruptMemory),
    TransportControl(close: closeMemory, dispose: disposeMemory,
      checkTransfer: transferMemory))

var readDone, readStarted: Event
proc pending(stream: sink Transport) {.passive.} =
  var byteBuffer = [0'u8]
  setEvent(addr readStarted)
  assert recvInto(stream, byteBuffer) == ResourceClosed
  setEvent(addr readDone)

proc pendingWrite(stream: sink Transport) {.passive.} =
  let payload = [1'u8, 2, 3, 4, 5, 6]
  let outcome = writeAll(stream, payload, afterMs(2000))
  assert outcome.bytes == payload.len and outcome.error == 0
  setEvent(addr writeDone)

proc main() {.passive.} =
  block:
    let stream = createMemory()
    let alias = stream
    assert destroyed == 0
    let taken = takeTransport(stream)
    assert taken.code == 0
    assert not stream.isOpen and not alias.isOpen
    let owner = taken.value
    assert owner != nil
    if owner != nil:
      var bytes = [1'u8, 2, 3, 4]
      let written = writeSome(owner, bytes)
      assert written.bytes == 3 and written.error == 0
      let read = readSome(owner, bytes)
      assert read.bytes == 3 and read.error == 0
      assert close(owner) == 0
      assert close(owner) == 0
      assert closes == 1
      assert recvInto(owner, bytes) == ResourceClosed
  assert destroyed == 1
  block:
    let stream = createMemory(true)
    assert trySpawnTask(pending(stream))
    assert wait(addr readStarted, afterMs(2000)) == wrReady
    assert canTransfer(stream) == ResourceBusy
    assert dispose(stream) == ResourceBusy
    assert close(stream) == 0
    assert wait(addr readDone, afterMs(2000)) == wrReady
  assert closes == 2 and destroyed == 2
  block:
    let stream = createMemory()
    let response = [72'u8,84,84,80,47,49,46,48,32,50,48,48,13,10,13,10,99]
    assert writeAll(stream, response).bytes == response.len
    let head = readHead(stream, afterMs(2000))
    assert head.error == 0 and head.length == response.len - 1
    var body = [0'u8]
    assert recvInto(stream, body) == 1 and body[0] == 99
    assert close(stream) == 0
  block:
    let stream = createMemory()
    var longHead = default(array[8192, byte])
    for i in 0..<longHead.len: longHead[i] = 65
    assert writeAll(stream, longHead).bytes == longHead.len
    let head = readHead(stream, afterMs(2000))
    assert head.error == TooLong and head.length == longHead.len
    assert close(stream) == 0
  block:
    let stream = createMemory(pauseWrites=true)
    assert trySpawnTask(pendingWrite(stream))
    assert wait(addr writeStarted, afterMs(2000)) == wrReady
    var bytes = [0'u8, 0, 0]
    assert sendFrom(stream, bytes) == ResourceBusy
    assert recvInto(stream, bytes) == 3
    assert bytes[0] == 1 and bytes[2] == 3
    setEvent(addr writeContinue)
    assert wait(addr writeDone, afterMs(2000)) == wrReady
    assert close(stream) == 0
  echo "PASS retained transport lifetime, transfer, partial I/O, write exclusion and close drain"

assert runMain(main())
