# Shared Sparkle CLI helpers. Source from other scripts after setting root_dir.
# The private EdDSA key stays in the login Keychain and is never written to disk.

SPARKLE_VERSION="2.9.2"
SPARKLE_ACCOUNT="timenbar"
SPARKLE_FEED_URL="https://ckcollab.github.io/TimenBar/appcast.xml"
SPARKLE_DOWNLOAD_PREFIX="https://github.com/ckcollab/TimenBar/releases/download"
SPARKLE_ARCHIVE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"

ensure_sparkle_tools() {
  local tools_dir="$root_dir/.sparkle/$SPARKLE_VERSION"
  local bin="$tools_dir/bin"
  if [[ ! -x "$bin/sign_update" || ! -x "$bin/generate_keys" ]]; then
    mkdir -p "$tools_dir"
    local archive="$tools_dir/Sparkle-${SPARKLE_VERSION}.tar.xz"
    print "Downloading Sparkle $SPARKLE_VERSION CLI tools..."
    curl -fsSL "$SPARKLE_ARCHIVE_URL" -o "$archive"
    tar -xJf "$archive" -C "$tools_dir"
    if [[ ! -x "$bin/sign_update" ]]; then
      local nested
      nested="$(find "$tools_dir" -type f -name sign_update | head -n 1)"
      [[ -n "$nested" ]] || die "Sparkle archive did not contain sign_update"
      bin="$(dirname "$nested")"
    fi
  fi
  SPARKLE_BIN="$bin"
}

sparkle_public_key() {
  ensure_sparkle_tools
  "$SPARKLE_BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p
}
