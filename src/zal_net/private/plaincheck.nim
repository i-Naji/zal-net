## Compiler plugin for the plain-data boundary; compiled only by Nimony.
## Inspect semchecked declarations: seq's len/data representation is not a
## borrowed plain object, despite structural matching on the pinned compiler.
import plugins

proc slot(n: NifCursor; index: int): NifCursor =
  result = firstChild(n)
  for i in 0 ..< index: skip result

proc declaration(defs: NifCursor; symbol: SymId; found: var bool): NifCursor =
  result = defs
  found = false
  var child = firstChild(defs)
  while child.hasMore:
    if slot(child, 0).symId == symbol:
      found = true
      return child
    skip child

type Origins = object
  sequence, text: SymId

proc origin(decl: NifCursor; symbol: SymId): SymId =
  ## Instantiated nominal types carry their actual generic head in slot 2.
  let arguments = slot(decl, 2)
  if arguments.typeKind == AtT: result = firstChild(arguments).symId
  else: result = symbol

proc hasLifetime(pragmas: NifCursor): bool =
  result = false
  if pragmas.kind != TagLit: return
  var p = firstChild(pragmas)
  while p.hasMore:
    if p.kind == TagLit and p.tagText in ["destroy", "copy", "dup"]:
      return true
    skip p

proc checkType(n: NifCursor; defs: NifCursor; missing: var seq[SymId]; deferred: var bool; origins: Origins): bool

proc checkFields(n: NifCursor; defs: NifCursor; missing: var seq[SymId]; deferred: var bool; origins: Origins): bool =
  result = true
  if n.otherKind == FldU:
    return checkType(slot(n, 3), defs, missing, deferred, origins)
  if n.kind == TagLit:
    var child = firstChild(n)
    while child.hasMore:
      if not checkFields(child, defs, missing, deferred, origins): result = false
      skip child

proc checkType(n: NifCursor; defs: NifCursor; missing: var seq[SymId]; deferred: var bool; origins: Origins): bool =
  if n.kind == DotToken: return true
  if n.kind == Symbol:
    var found = false
    let decl = declaration(defs, n.symId, found)
    if not found:
      missing.add n.symId
      return true
    if decl.otherKind in [TypevarU, StaticTypevarU]:
      deferred = true
      return true
    if decl.stmtKind != TypeS: return false
    let head = origin(decl, n.symId)
    if head == origins.sequence or head == origins.text: return false
    if hasLifetime(slot(decl, 3)): return false
    return checkType(slot(decl, 4), defs, missing, deferred, origins)
  case n.typeKind
  of IT, UT, FT, CT, BoolT, EnumT, OnumT, AnumT, PtrT, PointerT, CstringT:
    return true
  of RefT, ProctypeT, ClosureTupleT:
    return false
  of DistinctT, ArrayT, RangetypeT, SetT, TypedescT:
    return checkType(firstChild(n), defs, missing, deferred, origins)
  of ObjectT:
    result = checkType(firstChild(n), defs, missing, deferred, origins)
    if not checkFields(n, defs, missing, deferred, origins): result = false
  of TupleT:
    result = true
    var child = firstChild(n)
    while child.hasMore:
      let typ = if child.otherKind == KvU: slot(child, 1) else: child
      if not checkType(typ, defs, missing, deferred, origins): result = false
      skip child
  else:
    result = false

proc transform(input, defs: NifCursor): NifBuilder =
  var typ = callArgs(input)
  var sequence = typ
  skip sequence
  var text = sequence
  skip text
  if typ.typeKind == TypedescT: typ = firstChild(typ)
  if sequence.typeKind == TypedescT: sequence = firstChild(sequence)
  if text.typeKind == TypedescT: text = firstChild(text)
  var origins = default(Origins)
  var missing: seq[SymId] = @[]
  var found = false
  let sequenceDecl = declaration(defs, sequence.symId, found)
  if not found: missing.add sequence.symId
  else: origins.sequence = origin(sequenceDecl, sequence.symId)
  let stringDecl = declaration(defs, text.symId, found)
  if not found: missing.add text.symId
  else: origins.text = origin(stringDecl, text.symId)
  if missing.len > 0: return needTypes(missing)
  var deferred = false
  let valid = checkType(typ, defs, missing, deferred, origins)
  if missing.len > 0: return needTypes(missing)
  if deferred: return deferExpansion()
  result = createTree()
  if valid:
    result.withTree TrueX, NoLineInfo: discard
  else:
    result.withTree FalseX, NoLineInfo: discard

let input = loadPluginInput()
let defs = loadTypeDefinitions()
saveTree transform(input, defs)
