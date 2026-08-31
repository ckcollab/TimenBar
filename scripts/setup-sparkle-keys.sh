#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
project_file="$root_dir/TimenBar.xcodeproj/project.pbxproj"
generator_file="$root_dir/scripts/generate_project.rb"

die() {
  print -u2 "error: $*"
  exit 1
}

source "$root_dir/scripts/sparkle.sh"

ensure_sparkle_tools

print "Creating or reusing the TimenBar Sparkle signing key in your login Keychain."
print "macOS may prompt to allow Keychain access; choose Allow."
"$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT"

public_key="$("$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p)"
[[ -n "$public_key" && "$public_key" != *$'\n'* ]] || die "failed to read Sparkle public key"

/usr/bin/ruby - "$project_file" "$generator_file" "$public_key" <<'RUBY'
project_path, generator_path, public_key = ARGV

project = File.read(project_path)
count = project.scan(/INFOPLIST_KEY_SUPublicEDKey = "[^"]*";/).length
abort "unexpected SUPublicEDKey count in Xcode project: #{count}" unless count == 2
project.gsub!(/INFOPLIST_KEY_SUPublicEDKey = "[^"]*";/, "INFOPLIST_KEY_SUPublicEDKey = \"#{public_key}\";")
File.write(project_path, project)

generator = File.read(generator_path)
abort "missing SUPublicEDKey in generate_project.rb" unless generator.include?('INFOPLIST_KEY_SUPublicEDKey')
generator.gsub!(
  /settings\["INFOPLIST_KEY_SUPublicEDKey"\] = "[^"]*"/,
  "settings[\"INFOPLIST_KEY_SUPublicEDKey\"] = \"#{public_key}\""
)
File.write(generator_path, generator)
RUBY

print "Wrote SUPublicEDKey into the Xcode project. The private key is only in Keychain."
print "Public key: $public_key"
