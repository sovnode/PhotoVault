#!/bin/sh
# Runs the test suite with whichever developer toolchain is active.
#
# Usage: Scripts/test.sh [swift test options, e.g. --filter Selection]
#
# With Xcode selected this is a plain `swift test`. With only the Command Line
# Tools, three gaps have to be bridged by hand:
#
#   - XCTest doesn't exist there, so the suite is written against swift-testing,
#     which does ship in the CLT but not on the default framework or runtime
#     paths — hence the -F and the two -rpath entries.
#   - Swift 6.4's default build system doesn't load the CLT's testing macro
#     plugin, so its path is passed explicitly. (The older `native` build system
#     does load it, but it is deprecated, so this doesn't rely on it.)
#   - The macOS 27 SDK makes SwiftUI's @State a macro whose plugin ships only
#     with Xcode, so the app target can't compile here. Only the test product is
#     built, and it doesn't depend on the app.
#
# DEVELOPER_DIR overrides the selected toolchain for a single run, e.g.
#   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/test.sh
set -e
cd "$(dirname "$0")/.."

DEV="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}"

case "$DEV" in
    */CommandLineTools*)
        echo "Toolchain: Command Line Tools ($DEV) — building the test product only"
        CLT=/Library/Developer/CommandLineTools
        FW=$CLT/Library/Developer/Frameworks
        LIB=$CLT/Library/Developer/usr/lib
        PLUGINS=$CLT/usr/lib/swift/host/plugins/testing

        with_clt_paths() {
            "$@" \
                -Xswiftc -plugin-path -Xswiftc "$PLUGINS" \
                -Xswiftc -F -Xswiftc "$FW" \
                -Xlinker -F -Xlinker "$FW" \
                -Xlinker -rpath -Xlinker "$FW" \
                -Xlinker -rpath -Xlinker "$LIB"
        }

        with_clt_paths swift build --product PhotoVaultPackageTests
        with_clt_paths swift test --skip-build --disable-xctest --no-parallel "$@"
        ;;
    *)
        echo "Toolchain: $DEV"
        # --no-parallel because the containment suite snapshots the system temp
        # directory and the SQLite temp-dir variable, both process-wide.
        # --disable-xctest because every test is swift-testing; otherwise XCTest
        # reports "Executed 0 tests", which reads like the suite didn't run.
        exec swift test --disable-xctest --no-parallel "$@"
        ;;
esac
