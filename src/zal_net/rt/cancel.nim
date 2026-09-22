## Cancellation ownership and descriptor registration. Wait-node bookkeeping is private.
import zal_net/private/core/cancelstate
# Qualify cancel: its name also names this module (unqualified export crashes
# the current compiler's symbol lookup). Export only the supported operations.
export CancelToken, retain, release, cancelled, newCancelToken, cancelstate.cancel, adoptFd, releaseFd
export liveCancelTokens
