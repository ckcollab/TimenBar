#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
packages_dir="$root_dir/.sourcePackages"

xcodebuild -resolvePackageDependencies \
  -project "$root_dir/TimenBar.xcodeproj" \
  -scheme TimenBar \
  -clonedSourcePackagesDirPath "$packages_dir"

echo "TimenBar dependencies are ready."
