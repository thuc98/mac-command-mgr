#!/bin/bash
# Runs the unit + integration tests. Works with full Xcode or Command Line Tools only.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGS=()
CLT_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if ! xcodebuild -version >/dev/null 2>&1 && [ -d "$CLT_FRAMEWORKS/Testing.framework" ]; then
  # Command Line Tools ship Swift Testing but SwiftPM does not add it to the search paths.
  ARGS+=(-Xswiftc "-F$CLT_FRAMEWORKS" -Xlinker "-F$CLT_FRAMEWORKS" -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS"
        -Xlinker -rpath -Xlinker "$CLT_FRAMEWORKS/../usr/lib")
fi

exec swift test "${ARGS[@]+"${ARGS[@]}"}" "$@"
