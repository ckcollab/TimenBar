#!/bin/zsh
set -euo pipefail

root_dir="${0:A:h:h}"
info_plist="$root_dir/TimenBar/Info.plist"

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
[[ -f "$info_plist" ]] || die "missing $info_plist"

/usr/bin/ruby - "$info_plist" "$public_key" <<'RUBY'
plist_path, public_key = ARGV
plist = File.read(plist_path)
replaced = plist.sub!(
  %r{<key>SUPublicEDKey</key>\s*<string>[^<]*</string>},
  "<key>SUPublicEDKey</key>\n\t<string>#{public_key}</string>"
)
abort "missing SUPublicEDKey in #{plist_path}" unless replaced
File.write(plist_path, plist)
RUBY

print "Wrote SUPublicEDKey into TimenBar/Info.plist. The private key is only in Keychain."
print "Public key: $public_key"
