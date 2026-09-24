## An association index: 64-bit ids (a client session id, a hashed client
## address) to stable slot numbers. The caller keeps its per-slot records in
## its own array, grown to `cap` after `claim`; a slot number never changes
## while it is live, so it can be a poller tag. Open addressing with
## backward-shift deletion: churn leaves no tombstones, and a lookup never
## scans more than its cluster.

type
  AssocIndex* = object
    ids: seq[uint64]       # per slot, valid while live
    live: seq[bool]
    nextFree: seq[int]
    freeHead: int
    index: seq[int32]      # 2 x cap entries; -1 empty
    count*: int            # live slots
    cap*: int              # slots the caller must have room for
    maxCap: int

proc slotHash(id: uint64; mask: int): int {.inline.} =
  int(((id * 0x9E3779B97F4A7C15'u64) shr 17) and uint64(mask))

proc clearIndex(t: var AssocIndex) =
  var i = 0
  while i < t.index.len:
    t.index[i] = -1
    i = i + 1

proc initAssoc*(t: var AssocIndex; initial, maxSlots: int) =
  ## `initial` and `maxSlots` are powers of two.
  t.cap = initial
  t.maxCap = maxSlots
  t.ids = newSeq[uint64](initial)
  t.live = newSeq[bool](initial)
  t.nextFree = newSeq[int](initial)
  t.index = newSeq[int32](initial * 2)
  clearIndex(t)
  var i = 0
  while i < initial:
    t.nextFree[i] = if i + 1 < initial: i + 1 else: -1
    i = i + 1
  t.freeHead = 0
  t.count = 0

proc isLive*(t: AssocIndex; slot: int): bool {.inline.} =
  slot >= 0 and slot < t.cap and t.live[slot]

proc idOf*(t: AssocIndex; slot: int): uint64 {.inline.} = t.ids[slot]

proc lookup*(t: AssocIndex; id: uint64): int =
  ## The live slot with `id`, or -1.
  let mask = t.index.len - 1
  var h = slotHash(id, mask)
  while true:
    let s = int(t.index[h])
    if s < 0: return -1
    if t.ids[s] == id: return s
    h = (h + 1) and mask

proc indexPut(t: var AssocIndex; slot: int) =
  let mask = t.index.len - 1
  var h = slotHash(t.ids[slot], mask)
  while t.index[h] >= 0: h = (h + 1) and mask
  t.index[h] = int32(slot)

proc grow(t: var AssocIndex): bool =
  ## Doubles `cap`; slot numbers survive.
  let old = t.cap
  if old >= t.maxCap: return false
  let n = old * 2
  t.ids.setLen(n)
  t.live.setLen(n)
  t.nextFree.setLen(n)
  var i = old
  while i < n:
    t.nextFree[i] = if i + 1 < n: i + 1 else: t.freeHead
    i = i + 1
  t.freeHead = old
  t.cap = n
  t.index = newSeq[int32](n * 2)
  clearIndex(t)
  i = 0
  while i < old:
    if t.live[i]: indexPut(t, i)
    i = i + 1
  result = true

proc claim*(t: var AssocIndex; id: uint64): int =
  ## A free slot, indexed under `id` (not already present), or -1 at the
  ## limit. `cap` may have grown: the caller extends its records to it.
  if t.freeHead < 0 and not grow(t): return -1
  result = t.freeHead
  t.freeHead = t.nextFree[result]
  t.live[result] = true
  t.ids[result] = id
  indexPut(t, result)
  t.count = t.count + 1

proc release*(t: var AssocIndex; slot: int) =
  ## Unindex a live slot and return it to the free list.
  if not isLive(t, slot): return
  let mask = t.index.len - 1
  var i = slotHash(t.ids[slot], mask)
  while int(t.index[i]) != slot: i = (i + 1) and mask
  t.index[i] = -1
  var j = i
  while true:
    j = (j + 1) and mask
    let s = int(t.index[j])
    if s < 0: break
    let k = slotHash(t.ids[s], mask)
    let stays = if i <= j: i < k and k <= j else: i < k or k <= j
    if not stays:
      t.index[i] = int32(s)
      t.index[j] = -1
      i = j
  t.live[slot] = false
  t.nextFree[slot] = t.freeHead
  t.freeHead = slot
  t.count = t.count - 1
