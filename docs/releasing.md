# Releasing

Public releases require a Developer ID Application identity, hardened runtime, and Apple notarization credentials. Sparkle auto-updates require an EdDSA keypair in the release Mac's Keychain. Keep all private material out of the repository.

## One-time setup

```sh
brew install gh
gh auth login --web --git-protocol ssh
cp .env_sample .env
# Fill in TIMENBAR_APPLE_ID and TIMENBAR_TEAM_ID in .env, then:
scripts/configure-notarization.sh
scripts/setup-sparkle-keys.sh
```

`.env` is git-ignored and is read by the notarization setup and release scripts. `notarytool` securely prompts for the app-specific password instead of putting it in `.env`, the command, or shell history.

`scripts/setup-sparkle-keys.sh` stores the Sparkle **private** key in the login Keychain under the `timenbar` account and writes only the **public** key into `TimenBar/Info.plist`. Never export that private key into the repo, `.env`, or chat. Custom Sparkle keys must live in that plist; `INFOPLIST_KEY_SU*` build settings are dropped from the generated Info.plist.

The Sparkle feed is `https://ckcollab.github.io/TimenBar/appcast.xml`, served from `docs/appcast.xml` on GitHub Pages (`/docs` on `master`). Enable Pages once:

```sh
gh api repos/ckcollab/TimenBar/pages -X POST --input - <<'EOF'
{"source":{"branch":"master","path":"/docs"}}
EOF
```

Or in the GitHub UI: Settings → Pages → Deploy from branch `master`, folder `/docs`. If Pages is already configured, the API command returns an error you can ignore.

## Publishing a version

Start from a clean, up-to-date branch:

```sh
git status
git pull --ff-only
scripts/release.sh 0.2.0
```

The script requires a clean branch matching `origin`, confirms that the tag is new, increments the Xcode build number, updates the marketing version, runs the TimenBar unit tests, creates a universal archive, exports it with Developer ID signing, notarizes and staples the app, packages a ZIP and checksum, signs the ZIP with Sparkle, updates `docs/appcast.xml`, commits the version and appcast changes, creates an annotated tag, pushes the commit and tag atomically, and publishes a GitHub Release with generated notes. The appcast enclosure URL points at that GitHub Release asset. Artifacts are left in `release/<version>/`, which is ignored by git.

Useful safe modes:

```sh
# Exercise the entire build/sign/notarize/package path without changing git or GitHub.
scripts/release.sh 0.2.0 --prepare-only

# Build a signed but unnotarized test artifact. This mode cannot publish.
scripts/release.sh 0.2.0 --prepare-only --skip-notarization

# Push the tag but leave the GitHub Release unpublished for review.
scripts/release.sh 0.2.0 --draft
```

The GitHub CLI must already be authenticated with `gh auth login`. Credentials never belong in this script or the repository.

Builds that shipped without `SUPublicEDKey` will not check this feed. Users on those builds need to install the first Sparkle-enabled release manually; later releases update in-app.

Before tagging, run unit and UI tests, perform the opt-in disposable-account scenario, and verify the prior Sparkle-enabled release upgrades to the candidate. On a clean macOS 14 machine verify Gatekeeper, the stapled ticket, OAuth callback, launch at login, menu-bar controls, notifications, and sign-out revocation.
