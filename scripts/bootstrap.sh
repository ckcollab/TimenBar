#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
packages_dir="$root_dir/.sourcePackages"
sdk_file="$packages_dir/checkouts/swift-sdk/Sources/MCP/Base/Transports/NetworkTransport.swift"

xcodebuild -resolvePackageDependencies \
  -project "$root_dir/TimenBar.xcodeproj" \
  -scheme TimenBar \
  -clonedSourcePackagesDirPath "$packages_dir"

if rg -q "sendContinuationResumed|receiveContinuationResumed" "$sdk_file"; then
  chmod u+w "$sdk_file"
  patch -d "$packages_dir/checkouts/swift-sdk" -p1 < "$root_dir/patches/mcp-swift-sdk-0.11.0-xcode-26.6.patch"
fi

echo "TimenBar dependencies are ready."
