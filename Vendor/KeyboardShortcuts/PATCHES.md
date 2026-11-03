# Local patches to KeyboardShortcuts 3.1.0

Vendored from https://github.com/sindresorhus/KeyboardShortcuts at tag 3.1.0 (MIT, see `license`).

The upstream package uses the SwiftUI `#Preview` and `@Entry` macros. Their compiler
plugins ship only with full Xcode, so with just the Command Line Tools the package fails to
build ("plugin for module 'SwiftUIMacros' not found"). Patches, no behaviour change:

1. `Sources/KeyboardShortcuts/Recorder.swift`: removed the three `#Preview` blocks.
2. `Sources/KeyboardShortcuts/ConflictPolicy.swift`: replaced `@Entry` with an explicit
   `EnvironmentKey`.
3. `Package.swift`: removed the test target (tests and example app not vendored).
4. `Sources/KeyboardShortcuts/Utilities.swift`: localized strings load from
   `Bundle.keyboardShortcutsResources`, which looks in `Contents/Resources` of the app before
   the bundle root, instead of SwiftPM's `Bundle.module` (which only checks the .app root,
   where a bundle breaks code signing, and otherwise crashes).

With full Xcode installed you can point `Package.swift` back at the upstream URL (patch 4 is
still useful for a hand-assembled .app).
