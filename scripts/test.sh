#!/bin/sh
# Unit tests. Command Line Tools only: the Swift Testing macro plugin must be passed explicitly.
# Build outside ~/Claude (sync breaks build.db).
cd "$(dirname "$0")/.." && exec swift test --scratch-path "${VEC_BUILD:-/tmp/vec-build}" \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
