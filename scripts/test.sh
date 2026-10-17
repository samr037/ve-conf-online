#!/bin/sh
# Use the selected Swift toolchain (Xcode on CI, Command Line Tools locally).
set -eu
cd "$(dirname "$0")/.."
SWIFT="$(xcrun --find swift)"
PLUGINS="$(dirname "$SWIFT")/../lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
    set -- -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec "$SWIFT" test --scratch-path "${VEC_BUILD:-/tmp/vec-build}" "$@"
