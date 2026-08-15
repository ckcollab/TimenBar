#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
source_icon="$root_dir/Artwork/TimenBarIcon.svg"
output_dir="$root_dir/TimenBar/Assets.xcassets/AppIcon.appiconset"

for size in 16 32 64 128 256 512 1024; do
  magick -background none "$source_icon" -resize "${size}x${size}" "$output_dir/icon_${size}.png"
done
