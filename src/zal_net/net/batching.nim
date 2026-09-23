## Pure receive-batch policy. It changes syscall capacity, never waits to fill
## a batch and never changes the allocated MmsgBatch capacity or datagram order.
type ReceiveBudget* = object
  maximum: int
  wanted: int
  sparse: int

proc initReceiveBudget*(maximum: int): ReceiveBudget =
  ## A nonpositive maximum is an invalid, disabled budget (target zero).
  result = default(ReceiveBudget)
  if maximum > 0:
    result.maximum = maximum
    result.wanted = min(4, maximum)

proc target*(budget: ReceiveBudget): int {.inline.} = budget.wanted

proc observe*(budget: var ReceiveBudget; received: int) =
  ## Errors/empty polls retain the current target. Full batches grow promptly;
  ## eight sparse batches shrink it. Values above the target are invalid input
  ## to this policy and leave it unchanged. Calls stay on the owning thread.
  if received <= 0 or received > budget.wanted: return
  if received == budget.wanted:
    budget.wanted = budget.wanted + min(budget.wanted, budget.maximum - budget.wanted)
    budget.sparse = 0
  elif received <= budget.wanted div 4:
    budget.sparse += 1
    if budget.sparse >= 8:
      budget.wanted = max(1, budget.wanted div 2)
      budget.sparse = 0
  else:
    budget.sparse = 0
