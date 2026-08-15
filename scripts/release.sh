#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
project_file="$root_dir/TimenBar.xcodeproj/project.pbxproj"
generator_file="$root_dir/scripts/generate_project.rb"
scheme="TimenBar"
remote="origin"
default_notary_profile="${TIMENBAR_NOTARY_PROFILE:-TimenBar-Notary}"

usage() {
  cat <<'EOF'
Usage: scripts/release.sh <version> [options]

Build, sign, notarize, tag, and publish a TimenBar GitHub release.

Arguments:
  version                    Semantic version, for example 0.2.0 or v0.2.0

Options:
  --notary-profile <name>    notarytool Keychain profile (default: TimenBar-Notary)
  --draft                    Create a draft GitHub release
  --prepare-only             Build the artifact without committing, tagging, or publishing
  --skip-notarization        Only with --prepare-only; produce a signed test artifact
  --yes                      Skip the final interactive publishing confirmation
  -h, --help                 Show this help

The script requires a clean branch that matches origin, a Developer ID Application
identity for the configured Xcode team, and an authenticated GitHub CLI. Public
releases also require a notarytool Keychain profile.
EOF
}

die() {
  print -u2 "error: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

[[ $# -gt 0 ]] || { usage; exit 64; }

case "$1" in
  -h|--help)
    usage
    exit 0
    ;;
esac

version="${1#v}"
shift

notary_profile="$default_notary_profile"
draft=false
prepare_only=false
skip_notarization=false
assume_yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notary-profile)
      [[ $# -ge 2 ]] || die "--notary-profile requires a value"
      notary_profile="$2"
      shift 2
      ;;
    --draft)
      draft=true
      shift
      ;;
    --prepare-only)
      prepare_only=true
      shift
      ;;
    --skip-notarization)
      skip_notarization=true
      shift
      ;;
    --yes)
      assume_yes=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$' ]] || \
  die "version must look like 0.2.0 or 0.2.0-beta.1"

if $skip_notarization && ! $prepare_only; then
  die "--skip-notarization is restricted to --prepare-only builds"
fi

tag="v$version"
branch=""
team_id=""
current_version=""
current_build=""
next_build=""
release_dir="$root_dir/release/$version"
archive_path="$release_dir/TimenBar.xcarchive"
export_dir="$release_dir/export"
export_app="$export_dir/TimenBar.app"
notary_zip="$release_dir/TimenBar-$version-notary-upload.zip"
zip_name="TimenBar-$version.zip"
zip_path="$release_dir/$zip_name"
checksum_path="$zip_path.sha256"
export_options="$release_dir/ExportOptions.plist"
backup_dir=""
source_changes_committed=false

restore_version_files() {
  [[ -n "$backup_dir" && -d "$backup_dir" ]] || return 0
  cp "$backup_dir/project.pbxproj" "$project_file"
  cp "$backup_dir/generate_project.rb" "$generator_file"
}

handle_exit() {
  local exit_code=$?
  if [[ $exit_code -ne 0 && -n "$backup_dir" && "$source_changes_committed" == false ]]; then
    restore_version_files
    print -u2 "Release failed before the release commit; version files were restored."
  elif [[ $exit_code -ne 0 ]]; then
    if [[ "$source_changes_committed" == true ]]; then
      print -u2 "Release failed after the release commit. Inspect git and GitHub state before retrying."
    fi
  fi
}

trap handle_exit EXIT

cd "$root_dir"

for tool in git rg ruby xcodebuild xcrun codesign ditto shasum security; do
  require_command "$tool"
done

[[ -f "$project_file" ]] || die "Xcode project not found"
[[ -f "$generator_file" ]] || die "project generator not found"
[[ -z "$(git status --porcelain)" ]] || die "working tree must be clean"

branch="$(git branch --show-current)"
if ! $prepare_only; then
  [[ -n "$branch" ]] || die "releases cannot be created from a detached HEAD"
  command -v gh >/dev/null 2>&1 || \
    die "GitHub CLI is required; install it with 'brew install gh', then run 'gh auth login'"

  gh auth status --hostname github.com >/dev/null
  git fetch --quiet "$remote" "$branch" --tags

  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$remote/$branch")" ]] || \
    die "local $branch must exactly match $remote/$branch before releasing"

  if git show-ref --verify --quiet "refs/tags/$tag" || \
     git ls-remote --exit-code --tags "$remote" "refs/tags/$tag" >/dev/null 2>&1; then
    die "tag already exists: $tag"
  fi
fi

current_version="$(
  sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);/\1/p' "$project_file" | sort -u
)"
current_build="$(
  sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION = \([^;]*\);/\1/p' "$project_file" | sort -u
)"

[[ -n "$current_version" && "$current_version" != *$'\n'* ]] || \
  die "the Xcode project must contain one consistent marketing version"
[[ "$current_build" =~ '^[0-9]+$' ]] || \
  die "the Xcode project must contain one consistent integer build number"
[[ "$version" != "$current_version" ]] || die "$version is already the project version"

/usr/bin/ruby -e '
  require "rubygems"
  exit(Gem::Version.new(ARGV[0]) > Gem::Version.new(ARGV[1]) ? 0 : 1)
' "$version" "$current_version" || \
  die "new version $version must be greater than current version $current_version"

team_id="$(
  sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = \([^;]*\);/\1/p' "$project_file" | sort -u
)"
[[ "$team_id" =~ '^[A-Z0-9]{10}$' ]] || die "the Xcode project must contain one development team ID"

security find-identity -v -p codesigning | \
  rg -q '"Developer ID Application: .+ \('"$team_id"'\)"' || \
  die "no valid Developer ID Application identity found for team $team_id"

[[ ! -e "$release_dir" ]] || die "release workspace already exists: $release_dir"
mkdir -p "$release_dir"
backup_dir="$release_dir/source-backup"
mkdir -p "$backup_dir"
cp "$project_file" "$backup_dir/project.pbxproj"
cp "$generator_file" "$backup_dir/generate_project.rb"

next_build=$((current_build + 1))

/usr/bin/ruby - "$project_file" "$generator_file" "$version" "$next_build" <<'RUBY'
project_path, generator_path, version, build = ARGV

project = File.read(project_path)
marketing_count = project.scan(/^\s*MARKETING_VERSION = [^;]+;/).length
build_count = project.scan(/^\s*CURRENT_PROJECT_VERSION = [^;]+;/).length
abort "unexpected MARKETING_VERSION count: #{marketing_count}" unless marketing_count == 2
abort "unexpected CURRENT_PROJECT_VERSION count: #{build_count}" unless build_count == 2
project.gsub!(/^(\s*MARKETING_VERSION = )[^;]+;/, "\\1#{version};")
project.gsub!(/^(\s*CURRENT_PROJECT_VERSION = )[^;]+;/, "\\1#{build};")
File.write(project_path, project)

generator = File.read(generator_path)
generator_marketing_count = generator.scan(/settings\["MARKETING_VERSION"\] = "[^"]+"/).length
generator_build_count = generator.scan(/settings\["CURRENT_PROJECT_VERSION"\] = "[^"]+"/).length
abort "unexpected generated marketing version count" unless generator_marketing_count == 1
abort "unexpected generated build number count" unless generator_build_count == 1
generator.gsub!(/settings\["MARKETING_VERSION"\] = "[^"]+"/, "settings[\"MARKETING_VERSION\"] = \"#{version}\"")
generator.gsub!(/settings\["CURRENT_PROJECT_VERSION"\] = "[^"]+"/, "settings[\"CURRENT_PROJECT_VERSION\"] = \"#{build}\"")
File.write(generator_path, generator)
RUBY

cat > "$export_options" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>destination</key>
  <string>export</string>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
  <key>teamID</key>
  <string>$team_id</string>
</dict>
</plist>
EOF

if ! $prepare_only; then
  print "Release plan:"
  print "  Version:       $current_version → $version"
  print "  Build:         $current_build → $next_build"
  print "  Branch/tag:    $branch / $tag"
  print "  Team:          $team_id"
  print "  Notary profile: $notary_profile"
  $draft && print "  GitHub release: draft"

  if ! $assume_yes; then
    [[ -t 0 ]] || die "publishing from a non-interactive shell requires --yes"
    read "reply?Continue and publish this release? [y/N] "
    [[ "$reply" == [yY] || "$reply" == [yY][eE][sS] ]] || die "release cancelled"
  fi
fi

derived_data="$root_dir/.derivedData/Release"
module_cache="$root_dir/.derivedData/ReleaseModuleCache"
packages_dir="$root_dir/.sourcePackages"
package_cache="$root_dir/.packageCache"

common_xcode_args=(
  -project "$root_dir/TimenBar.xcodeproj"
  -scheme "$scheme"
  -derivedDataPath "$derived_data"
  -clonedSourcePackagesDirPath "$packages_dir"
  -packageCachePath "$package_cache"
  -disablePackageRepositoryCache
  -skipPackageUpdates
)

print "Running TimenBar unit tests..."
env \
  SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
  CLANG_MODULE_CACHE_PATH="$module_cache" \
  xcodebuild "${common_xcode_args[@]}" \
    -destination platform=macOS \
    -only-testing:TimenBarTests \
    CODE_SIGNING_ALLOWED=NO \
    test

print "Creating universal Release archive..."
env \
  SWIFTPM_MODULECACHE_OVERRIDE="$module_cache" \
  CLANG_MODULE_CACHE_PATH="$module_cache" \
  xcodebuild "${common_xcode_args[@]}" \
    -configuration Release \
    -destination generic/platform=macOS \
    -archivePath "$archive_path" \
    archive

print "Exporting with Developer ID signing..."
xcodebuild \
  -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "$export_options" \
  -allowProvisioningUpdates

codesign --verify --deep --strict --verbose=2 "$export_app"

if ! $skip_notarization; then
  print "Submitting to Apple notarization..."
  ditto -c -k --sequesterRsrc --keepParent "$export_app" "$notary_zip"
  xcrun notarytool submit "$notary_zip" \
    --keychain-profile "$notary_profile" \
    --wait
  xcrun stapler staple "$export_app"
  xcrun stapler validate "$export_app"
  spctl --assess --type execute --verbose=4 "$export_app"
fi

print "Packaging $zip_name..."
ditto -c -k --sequesterRsrc --keepParent "$export_app" "$zip_path"
(
  cd "$release_dir"
  shasum -a 256 "$zip_name" > "$zip_name.sha256"
)

if $prepare_only; then
  restore_version_files
  backup_dir=""
  trap - EXIT
  print "Prepared release artifact without changing git or GitHub:"
  print "  $zip_path"
  $skip_notarization && print "  Warning: this test artifact is signed but not notarized."
  exit 0
fi

git add "$project_file" "$generator_file"
git commit -m "Release $tag"
source_changes_committed=true
git tag -a "$tag" -m "TimenBar $version"

print "Pushing release commit and tag atomically..."
git push --atomic "$remote" "$branch" "$tag"

github_repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
release_args=(
  release create "$tag"
  "$zip_path#TimenBar $version"
  "$checksum_path#SHA-256 checksum"
  --repo "$github_repo"
  --title "TimenBar $version"
  --generate-notes
  --verify-tag
)

$draft && release_args+=(--draft)
[[ "$version" == *-* ]] && release_args+=(--prerelease)

print "Creating GitHub release..."
gh "${release_args[@]}"

backup_dir=""
trap - EXIT
print "Released TimenBar $version."
