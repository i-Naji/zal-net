import zal_net/private/runtime
## Sharded counters: one cache-line-padded slot per loop (or pool worker)
## plus one shared by every other thread, so counting on a hot path touches
## only the calling thread's line. Reads sum the slots; `takeDelta` reports
## what was added since the caller's last mark, for usage deltas. Create
## counters after `initRuntime`.

import std/atomics
import zal_net/rt

const SlotWords = 8   # 64 bytes per slot

type
  CounterObj = object
    shards: int
    slots: ptr UncheckedArray[int64]   # slot i at [i * SlotWords]
  ShardedCounter* = ptr CounterObj

  CounterSetObj = object
    n, shards, rowWords: int
    slots: ptr UncheckedArray[int64]   # shard s, counter i at [s * rowWords + i]
  CounterSet* = ptr CounterSetObj
    ## `n` counters (e.g. one per user), each sharded like ShardedCounter.

proc newShardedCounter*(): ShardedCounter =
  let shards = beShardCount()
  result = cast[ShardedCounter](alloc0(sizeof(CounterObj)))
  result.shards = shards
  result.slots = cast[ptr UncheckedArray[int64]](alloc0(shards * SlotWords * sizeof(int64)))

proc inc*(c: ShardedCounter; v = 1'i64) {.inline.} =
  var s = beShardId()
  if s >= c.shards: s = c.shards - 1
  discard atomicFetchAdd(c.slots[s * SlotWords], v, moRelaxed)

proc total*(c: ShardedCounter): int64 =
  result = 0
  var s = 0
  while s < c.shards:
    result = result + atomicLoad(c.slots[s * SlotWords], moRelaxed)
    s = s + 1

proc takeDelta*(c: ShardedCounter; mark: var int64): int64 =
  ## What was added since `mark`, which moves to the current total.
  let t = total(c)
  result = t - mark
  mark = t

proc freeCounter*(c: ShardedCounter) =
  dealloc(c.slots)
  dealloc(c)

proc newCounterSet*(n: int): CounterSet =
  let shards = beShardCount()
  # Round each shard's row up to whole cache lines.
  let rowWords = ((n + SlotWords - 1) div SlotWords) * SlotWords
  result = cast[CounterSet](alloc0(sizeof(CounterSetObj)))
  result.slots = cast[ptr UncheckedArray[int64]](alloc0(shards * rowWords * sizeof(int64)))
  result.n = n
  result.shards = shards
  result.rowWords = rowWords

proc inc*(s: CounterSet; idx: int; v = 1'i64) {.inline.} =
  var sh = beShardId()
  if sh >= s.shards: sh = s.shards - 1
  discard atomicFetchAdd(s.slots[sh * s.rowWords + idx], v, moRelaxed)

proc total*(s: CounterSet; idx: int): int64 =
  result = 0
  var sh = 0
  while sh < s.shards:
    result = result + atomicLoad(s.slots[sh * s.rowWords + idx], moRelaxed)
    sh = sh + 1

proc clear*(s: CounterSet; idx: int) =
  ## Zero counter `idx` on every shard, for reuse. Adds racing with the
  ## clear may survive it; clear a counter nobody is adding to.
  var sh = 0
  while sh < s.shards:
    atomicStore(s.slots[sh * s.rowWords + idx], 0'i64, moRelaxed)
    sh = sh + 1

proc len*(s: CounterSet): int {.inline.} = s.n

proc freeCounterSet*(s: CounterSet) =
  dealloc(s.slots)
  dealloc(s)
