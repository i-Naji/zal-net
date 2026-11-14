## The association index against a reference model, across growth, so
## backward-shift deletion never loses or duplicates an id.
import std/assertions
import std/syncio
import zal_net/private/datagram/index

proc main() =
  var t = default(AssocIndex)
  initAssoc(t, 8, 1 shl 16)
  var ids: seq[uint64] = @[]
  var slots: seq[int] = @[]
  var x = 0x243F6A8885A308D3'u64
  var step = 0
  var grew = 0
  while step < 200_000:
    x = x xor (x shl 13)
    x = x xor (x shr 7)
    x = x xor (x shl 17)
    let r = x
    if ids.len < 3000 and (ids.len == 0 or (r and 3) != 0):
      x = x xor (x shl 13)
      x = x xor (x shr 7)
      x = x xor (x shl 17)
      let id = x and 0xFFFF_FFFF'u64   # narrow ids: more clustering
      if lookup(t, id) < 0:
        let before = t.cap
        let s = claim(t, id)
        assert s >= 0 and isLive(t, s) and idOf(t, s) == id
        if t.cap > before: grew = grew + 1
        ids.add id
        slots.add s
    else:
      let k = int(r mod uint64(ids.len))
      release(t, slots[k])
      assert lookup(t, ids[k]) < 0 and not isLive(t, slots[k])
      let lastId = ids[ids.len - 1]
      let lastSlot = slots[slots.len - 1]
      ids[k] = lastId
      slots[k] = lastSlot
      ids.shrink(ids.len - 1)
      slots.shrink(slots.len - 1)
    if step mod 997 == 0:
      var i = 0
      while i < ids.len:
        assert lookup(t, ids[i]) == slots[i]
        i = i + 1
      assert t.count == ids.len
    step = step + 1
  assert grew >= 8
  echo "PASS 200k operations, ", ids.len, " live, grew ", grew, " times to ", t.cap

  var small = default(AssocIndex)
  initAssoc(small, 4, 8)
  var i = 0
  while i < 8:
    assert claim(small, uint64(i + 1)) >= 0
    i = i + 1
  assert claim(small, 99'u64) == -1
  release(small, lookup(small, 3'u64))
  assert claim(small, 99'u64) >= 0
  echo "PASS limit"

main()
