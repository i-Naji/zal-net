## Control for c43: a distinct implementation name preserves the package alias.
import std/[assertions, syncio]
import fixtures/aliasexport/cleanpackage as tls
var config: nil tls.Config = nil
assert config == nil
echo "ok"
