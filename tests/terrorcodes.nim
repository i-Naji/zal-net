## Diagnostic helpers remain independent of the process runtime.
import std/[assertions, syncio]
import zal_net/errors as neterrors

assert neterrors.describe(InvalidInput) == "invalid input"
assert neterrors.describe(12) == "12 bytes transferred"
assert neterrors.describe(-9) == "OS error 9"
assert neterrors.describe(-400_001) == "library error -400001"
echo "PASS qualified errors preserve native codes and unknown package ranges"
