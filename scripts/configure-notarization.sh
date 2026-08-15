#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
env_file="${TIMENBAR_ENV_FILE:-$root_dir/.env}"

die() {
  print -u2 "error: $*"
  exit 1
}

[[ -f "$env_file" ]] || \
  die "missing $env_file; copy .env_sample to .env and fill in your Apple Developer details"

# .env is a local, git-ignored zsh environment file. It should contain only the
# non-secret identifiers shown in .env_sample, never an app-specific password.
set -a
source "$env_file"
set +a

: "${TIMENBAR_APPLE_ID:?Set TIMENBAR_APPLE_ID in .env}"
: "${TIMENBAR_TEAM_ID:?Set TIMENBAR_TEAM_ID in .env}"
notary_profile="${TIMENBAR_NOTARY_PROFILE:-TimenBar-Notary}"

[[ "$TIMENBAR_TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] || \
  die "TIMENBAR_TEAM_ID must be a 10-character Apple Developer team ID"

project_team_ids="$(
  sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = \([^;]*\);/\1/p' \
    "$root_dir/TimenBar.xcodeproj/project.pbxproj" | sort -u
)"
[[ "$project_team_ids" == "$TIMENBAR_TEAM_ID" ]] || \
  die "TIMENBAR_TEAM_ID does not match the team configured in the Xcode project"

print "Saving Apple notarization credentials to Keychain profile: $notary_profile"
print "Apple will securely prompt for your app-specific password."
xcrun notarytool store-credentials "$notary_profile" \
  --apple-id "$TIMENBAR_APPLE_ID" \
  --team-id "$TIMENBAR_TEAM_ID"

print "Notarization profile configured."
