#!/usr/bin/env bash
set -euo pipefail
# Runs the exact production geometry source and shared XCTest cases without AppKit.
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/tidest-layout-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
swift_bin="${SWIFT_BIN:-swift}"
mkdir -p "$test_dir/Sources/LayoutLogic" "$test_dir/Tests/LayoutLogicTests" "$test_dir/cache" "$test_dir/config" "$test_dir/security"
cp "$repo_dir/tidest/MultiWindowLayout.swift" "$test_dir/Sources/LayoutLogic/"
cp "$repo_dir/tidestTests/MultiWindowLayoutTests.swift" "$test_dir/Tests/LayoutLogicTests/"
cat > "$test_dir/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "LayoutLogic", targets: [
    .target(name: "LayoutLogic", swiftSettings: [.unsafeFlags(["-default-isolation", "MainActor"])]),
    .testTarget(name: "LayoutLogicTests", dependencies: ["LayoutLogic"])
], swiftLanguageModes: [.v5])
SWIFT
export CLANG_MODULE_CACHE_PATH="$test_dir/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$test_dir/cache/swift"
"$swift_bin" test --package-path "$test_dir" --cache-path "$test_dir/cache" --config-path "$test_dir/config" --security-path "$test_dir/security"
