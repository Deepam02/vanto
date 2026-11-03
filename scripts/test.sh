#!/bin/zsh
# Build and run the unit tests. With full Xcode, `swift test` works directly; with only the
# Command Line Tools it builds the Swift Testing bundle but runs nothing, so this script
# loads the bundle into a tiny runner (scripts/TestRunner.swift) that calls Swift Testing.
set -euo pipefail
cd "${0:A:h}/.."

swift build --build-tests "$@"

if xcode-select -p 2>/dev/null | grep -q CommandLineTools; then
  F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  RUNNER=.build/test-runner
  if [[ ! -x $RUNNER || scripts/TestRunner.swift -nt $RUNNER ]]; then
    swiftc -parse-as-library -F $F -Xlinker -rpath -Xlinker $F -Xlinker -rpath -Xlinker $L \
      scripts/TestRunner.swift -o $RUNNER
  fi
  BUNDLE=$(swift build --show-bin-path)/VoiceCommandPackageTests.xctest/Contents/MacOS/VoiceCommandPackageTests
  exec $RUNNER $BUNDLE
else
  exec swift test --skip-build
fi
