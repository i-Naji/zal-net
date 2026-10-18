## Retained UDP owner. One receive and one send may overlap.
## Queued owning tasks must use a `sink UdpSocketRef` argument on this pin.
## Close cancels readiness waits and drains them before descriptor release;
## it never shuts down an unconnected UDP socket or closes a borrowed handle.
import zal_net/[rt, errors, buffers], zal_net/rt/[sync, cancel]
import zal_net/raw/[udp, mmsg], zal_net/net/address
import zal_net/ownership
import std/ticketlocks
import zal_net/private/core/[iocancel, udpops]

export ownership
from zal_net/net/datagraminfo import DatagramInfo
export DatagramInfo

type
  UdpSocketObj = object
    socket: UdpSocket                 ## sole stable raw owner
    life: OwnerLife                   ## synchronized admission/drain
    stop: nil CancelToken             ## owned once per socket, not per operation
    failureLock: TicketLock
    readFailure, writeFailure: IoFailure
  UdpSocketRef* = ref UdpSocketObj
  UdpSocketResult* = object
    value*: nil UdpSocketRef          ## caller owns on success; nil on failure
    code*: int                       ## zero success; negative native/library error

proc `=destroy`(owner: var UdpSocketObj) =
  ## Every pending operation retains its owner; destruction is quiescent.
  close(owner.socket)
  release(owner.stop)

proc newOwner(): UdpSocketRef =
  ## Typed allocation keeps recursively defaulted construction outside templates.
  UdpSocketRef()

proc initialized(owner: UdpSocketRef; code: int): UdpSocketResult =
  result = default(UdpSocketResult)
  result.code = code
  if code == 0:
    initOwnerLife(owner.life)
    owner.stop = newCancelToken()
    result.value = owner

proc takeUdpSocketRef*(socket: UdpSocketPtr): UdpSocketResult =
  ## Transfer a quiescent socket. Failure preserves it.
  if stopping(): return UdpSocketResult(code: ResourceClosed)
  if not socket[].ok: return UdpSocketResult(code: ResourceClosed)
  let owner = newOwner()
  owner.socket = takeUdp(socket)
  result = initialized(owner, 0)

proc takeUdpSocketRef*(socket: var UdpSocket): UdpSocketResult {.inline.} =
  takeUdpSocketRef(addr socket)

proc bindUdpRef*(port: uint16 = 0; host = ""; timeoutMs = DefaultTimeoutMs;
                 reusePort = false): UdpSocketResult =
  if stopping(): return UdpSocketResult(code: ResourceClosed)
  let owner = newOwner()
  let code = bindUdpInto(addr owner.socket, port, host, timeoutMs, reusePort)
  result = initialized(owner, code)

proc openUdpRef*(timeoutMs = DefaultTimeoutMs): UdpSocketResult =
  if stopping(): return UdpSocketResult(code: ResourceClosed)
  let owner = newOwner()
  let code = openUdpInto(addr owner.socket, timeoutMs)
  result = initialized(owner, code)

proc connectUdpRef*(remote: SocketAddress; timeoutMs = DefaultTimeoutMs;
                    deadline: Deadline = never; tok: nil CancelToken = nil): UdpSocketResult =
  if stopping(): return UdpSocketResult(code: ResourceClosed)
  let owner = newOwner()
  let code = connectUdpInto(addr owner.socket, remote, timeoutMs, deadline, tok)
  result = initialized(owner, code)

proc rawSocket(owner: UdpSocketRef): UdpSocketPtr {.inline.} = addr owner.socket
proc borrowedHandle(owner: UdpSocketRef): cint {.inline.} = nativeHandle(owner.socket)
proc ownerLife(owner: UdpSocketRef): ptr OwnerLife {.inline.} = addr owner.life
proc cancellation(owner: UdpSocketRef; tok: nil CancelToken): IoCancellation {.inline.} =
  ioCancellation(tok, owner.stop)
proc family*(owner: UdpSocketRef): cint {.inline.} = owner.socket.family
proc timeout(owner: UdpSocketRef): int {.inline.} = owner.socket.timeoutMs

template connectUdpRef*(host: string; port: uint16; timeoutMs = DefaultTimeoutMs;
                         deadline: Deadline = never; tok: nil CancelToken = nil): UdpSocketResult =
  block:
    var outcome = default(UdpSocketResult)
    if stopping(): outcome.code = ResourceClosed
    else:
      let name = host
      let owner = newOwner()
      let code = connectUdpInto(rawSocket(owner), name, port, timeoutMs, deadline, tok)
      outcome = initialized(owner, code)
    outcome

proc state*(owner: UdpSocketRef): OwnerState {.inline.} = state(owner.life)
proc cleanup(owner: UdpSocketRef)
proc finishControl(owner: UdpSocketRef) =
  endControl(owner.life)
  cleanup(owner)

proc nativeHandle*(owner: UdpSocketRef): cint =
  if beginControl(owner.life) != 0: return -1
  result = nativeHandle(owner.socket)
  finishControl(owner)
proc localAddress*(owner: UdpSocketRef): SocketAddress =
  if beginControl(owner.life) != 0: return default(SocketAddress)
  result = localAddress(owner.socket)
  finishControl(owner)
proc remoteAddress*(owner: UdpSocketRef): SocketAddress =
  if beginControl(owner.life) != 0: return default(SocketAddress)
  result = remoteAddress(owner.socket)
  finishControl(owner)
proc lastReadFailure*(owner: UdpSocketRef): IoFailure =
  owner.failureLock.acquire()
  result = owner.readFailure
  owner.failureLock.release()
proc lastWriteFailure*(owner: UdpSocketRef): IoFailure =
  owner.failureLock.acquire()
  result = owner.writeFailure
  owner.failureLock.release()
proc recordRead*(owner: UdpSocketRef; code, transferred: int) =
  owner.failureLock.acquire()
  owner.readFailure = IoFailure(code: code, transferred: transferred)
  owner.failureLock.release()
proc recordWrite*(owner: UdpSocketRef; code, transferred: int) =
  owner.failureLock.acquire()
  owner.writeFailure = IoFailure(code: code, transferred: transferred)
  owner.failureLock.release()

proc beginOperation(owner: UdpSocketRef; write: bool): int =
  if stopping(): return ResourceClosed
  result = beginBorrow(owner.life, write)

proc finishClose(owner: UdpSocketRef) =
  ## All I/O acknowledgements have finished; release the descriptor and token.
  close(owner.socket)
  markClosed(owner.life)

proc cleanup(owner: UdpSocketRef) =
  if claimOwnerCleanup(owner.life): finishClose(owner)

proc endOperation(owner: UdpSocketRef; write: bool) =
  endBorrow(owner.life, write)
  cleanup(owner)

template recvFrom*(owner: UdpSocketRef; bytes: var openArray[byte];
                    source: var SocketAddress; deadline: Deadline = never;
                    tok: nil CancelToken = nil): int =
  block:
    let held = owner
    var count = beginOperation(held, false)
    if count == 0:
      defer: endOperation(held, false)
      count = udpRecvFrom(borrowedHandle(held), timeout(held), dataPtr(bytes), bytes.len,
                          addr source, deadline, cancellation(held, tok))
      if count < 0 and state(held) == ownerClosing: count = ResourceClosed
    count

template sendTo*(owner: UdpSocketRef; bytes: openArray[byte]; to: SocketAddress;
                  deadline: Deadline = never; tok: nil CancelToken = nil): int =
  block:
    let held = owner
    var count = beginOperation(held, true)
    if count == 0:
      defer: endOperation(held, true)
      count = udpSendTo(borrowedHandle(held), family(held), timeout(held),
                        dataPtr(bytes), bytes.len, to, deadline, cancellation(held, tok))
      if count < 0 and state(held) == ownerClosing: count = ResourceClosed
    count

template recv*(owner: UdpSocketRef; bytes: var openArray[byte];
                deadline: Deadline = never; tok: nil CancelToken = nil): int =
  block:
    let held = owner
    var count = beginOperation(held, false)
    if count == 0:
      defer: endOperation(held, false)
      count = udpRecv(borrowedHandle(held), timeout(held), dataPtr(bytes), bytes.len,
                      deadline, cancellation(held, tok))
      if count < 0 and state(held) == ownerClosing: count = ResourceClosed
    count

template send*(owner: UdpSocketRef; bytes: openArray[byte];
                deadline: Deadline = never; tok: nil CancelToken = nil): int =
  block:
    let held = owner
    var count = beginOperation(held, true)
    if count == 0:
      defer: endOperation(held, true)
      count = udpSend(borrowedHandle(held), timeout(held), dataPtr(bytes), bytes.len,
                      deadline, cancellation(held, tok))
      if count < 0 and state(held) == ownerClosing: count = ResourceClosed
    count

template recvBatch*(owner: UdpSocketRef; batch: var MmsgBatch;
                    deadline: Deadline = never; tok: nil CancelToken = nil): int =
  block:
    let held = owner
    var count = beginOperation(held, false)
    if count == 0:
      defer: endOperation(held, false)
      count = udpRecvBatch(borrowedHandle(held), timeout(held), addr batch,
                           deadline, cancellation(held, tok))
      if count < 0 and state(held) == ownerClosing: count = ResourceClosed
    count

template sendBatch*(owner: UdpSocketRef; batch: var MmsgBatch; n: int;
                    deadline: Deadline = never; tok: nil CancelToken = nil): int =
  block:
    let held = owner
    var count = beginOperation(held, true)
    if count == 0:
      defer: endOperation(held, true)
      count = udpSendBatch(borrowedHandle(held), timeout(held), addr batch, n,
                           deadline, cancellation(held, tok))
      if count < 0 and state(held) == ownerClosing: count = ResourceClosed
    count

proc startClose(owner: UdpSocketRef): int =
  result = beginClose(owner.life, true)
  if result == ResourceClosed: return 0
  if result != 0: return
  cancel(owner.stop)
  finishInterrupt(owner.life)
  cleanup(owner)

template close*(owner: UdpSocketRef; deadline: Deadline = never): int =
  ## Reject new work and cancel waits without recycling the descriptor. A
  ## deadline leaves eventual cleanup with the final retaining operation.
  block:
    let held = owner
    var code = startClose(held)
    if code == 0: code = drainClose(ownerLife(held), deadline)
    code


template recvFrom*(owner: UdpSocketRef; bytes: var openArray[byte];
                    info: var DatagramInfo; deadline: Deadline = never;
                    tok: nil CancelToken = nil): int =
  block:
    let held = owner
    var count = beginOperation(held, false)
    if count == 0:
      defer: endOperation(held, false)
      count = udpRecvInfo(borrowedHandle(held), timeout(held), dataPtr(bytes), bytes.len,
                          addr info, deadline, cancellation(held, tok))
      if count < 0 and state(held) == ownerClosing: count = ResourceClosed
    count

template sendWithSource*(owner: UdpSocketRef; bytes: openArray[byte]; to: SocketAddress;
                         source: IpAddress; ifIndex = 0'u32; deadline: Deadline = never;
                         tok: nil CancelToken = nil): int =
  block:
    let held = owner
    var count = beginOperation(held, true)
    if count == 0:
      defer: endOperation(held, true)
      count = udpSendWithSource(borrowedHandle(held), family(held), timeout(held),
                                dataPtr(bytes), bytes.len, to, source, ifIndex,
                                deadline, cancellation(held, tok))
      if count < 0 and state(held) == ownerClosing: count = ResourceClosed
    count

proc configurable(owner: UdpSocketRef): bool =
  ## Settings hold exclusive admission through the synchronous native call.
  if stopping(): return false
  result = beginExclusiveControl(owner.life) == 0

proc enableInfo*(owner: UdpSocketRef): bool =
  if not configurable(owner): return false
  result = enableInfo(owner.socket)
  finishControl(owner)
proc joinGroup*(owner: UdpSocketRef; group: IpAddress; ifIndex = 0'u32): bool =
  if not configurable(owner): return false
  result = joinGroup(owner.socket, group, ifIndex)
  finishControl(owner)
proc leaveGroup*(owner: UdpSocketRef; group: IpAddress; ifIndex = 0'u32): bool =
  if not configurable(owner): return false
  result = leaveGroup(owner.socket, group, ifIndex)
  finishControl(owner)
proc setMulticastInterface*(owner: UdpSocketRef; ifIndex: uint32; v6 = false): bool =
  if not configurable(owner): return false
  result = setMulticastInterface(owner.socket, ifIndex, v6)
  finishControl(owner)
proc setMulticastTtl*(owner: UdpSocketRef; ttl: int; v6 = false): bool =
  if not configurable(owner): return false
  result = setMulticastTtl(owner.socket, ttl, v6)
  finishControl(owner)
proc setMulticastLoop*(owner: UdpSocketRef; on: bool; v6 = false): bool =
  if not configurable(owner): return false
  result = setMulticastLoop(owner.socket, on, v6)
  finishControl(owner)
proc setBroadcast*(owner: UdpSocketRef; on = true): bool =
  if not configurable(owner): return false
  result = setBroadcast(owner.socket, on)
  finishControl(owner)
