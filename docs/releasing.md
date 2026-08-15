# Releasing

Public releases require a Developer ID Application identity, hardened runtime, and Apple notarization credentials. Sparkle auto-update releases additionally require an EdDSA keypair. Keep all private material out of the repository.

## Local GitHub releases

Use the guarded local release script after configuring a `notarytool` Keychain profile named `TimenBar-Notary`:

```sh
xcrun notarytool store-credentials TimenBar-Notary \
  --apple-id "YOUR_APPLE_ID" \
  --team-id MMJZRMH2BA

scripts/release.sh 0.2.0
```

`notarytool` securely prompts for the app-specific password instead of putting it in the command or shell history.

The script requires a clean branch matching `origin`, confirms that the tag is new, increments the Xcode build number, updates the marketing version, runs the TimenBar unit tests, creates a universal archive, exports it with Developer ID signing, notarizes and staples the app, packages a ZIP and checksum, commits the version changes, creates an annotated tag, pushes the commit and tag atomically, and publishes a GitHub Release with generated notes.

Useful safe modes:

```sh
# Exercise the entire build/sign/notarize/package path without changing git or GitHub.
scripts/release.sh 0.2.0 --prepare-only

# Build a signed but unnotarized test artifact. This mode cannot publish.
scripts/release.sh 0.2.0 --prepare-only --skip-notarization

# Push the tag but leave the GitHub Release unpublished for review.
scripts/release.sh 0.2.0 --draft
```

Generated artifacts are kept under `release/<version>/`, which is ignored by git. The GitHub CLI must already be authenticated with `gh auth login`. Credentials never belong in this script or the repository.

When auto-updates are enabled later, configure `SUFeedURL` for the GitHub Pages appcast and `SUPublicEDKey` for the Sparkle public key. Extend the release process to sign the final archive with Sparkle, update the appcast, and upload the appcast alongside the GitHub Release.

Before tagging, run unit and UI tests, perform the opt-in disposable-account scenario, and verify the prior release upgrades to the candidate through Sparkle. On a clean macOS 14 machine verify Gatekeeper, the stapled ticket, OAuth callback, launch at login, menu-bar controls, notifications, and sign-out revocation.
