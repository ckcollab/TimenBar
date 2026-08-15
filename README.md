<p align="center">
  <img src="Artwork/TimenBarIcon.svg" alt="TimenBar logo" width="160">
</p>

<h1 align="center">TimenBar</h1>

TimenBar is an unofficial, native macOS menu-bar client for [Timen](https://www.gettimen.com). It tracks live time, keeps a durable offline outbox, detects idle time without Accessibility permission, and connects only through Timen's documented OAuth-enabled MCP endpoint.

TimenBar is independent software and is not affiliated with or endorsed by Timen.

## Requirements

- macOS 14 or newer
- Xcode 16.3 or newer (the project is configured for Swift 6 strict concurrency)
- A Timen account with access to the published MCP integration
- ImageMagick only when regenerating icon PNGs

## Build

```sh
./scripts/bootstrap.sh
open TimenBar.xcodeproj
```

Choose the `TimenBar` scheme and Run. The app is an `LSUIElement` accessory app, so it appears only in the menu bar. The main status item opens the weekly panel; the adjacent play/pause item restarts the most recent timer or stops the running timer.

The project pins the official Swift MCP SDK to `0.11.0` and Sparkle to `2.9.2`. Xcode 26.6 diagnoses two captured continuation flags inside MCP 0.11.0 as Swift 6 data races. `bootstrap.sh` applies the small reviewed compatibility patch in `patches/` to the resolved checkout; no API behavior or version is changed.

## Releasing

One-time setup on a release Mac:

```sh
brew install gh
gh auth login --web --git-protocol ssh
cp .env_sample .env
# Fill in TIMENBAR_APPLE_ID and TIMENBAR_TEAM_ID in .env, then:
scripts/configure-notarization.sh
```

The local `.env` file is git-ignored. `notarytool` will securely prompt for your app-specific password; do not put that password in `.env`, the repository, or the command itself.

For each release, start from a clean, up-to-date branch and pass the new version number to the release script:

```sh
git status
git pull --ff-only
scripts/release.sh 0.2.0
```

The script updates the app and build versions, runs the unit tests, creates and Developer ID-signs a universal archive, notarizes and staples the app, packages a ZIP and checksum, commits and tags the version as `v0.2.0`, pushes it, and creates the GitHub Release. Artifacts are left in `release/0.2.0/`.

Useful rehearsal and review modes:

```sh
# Build the signed release artifact without changing git or GitHub.
scripts/release.sh 0.2.0 --prepare-only

# Build an unnotarized test artifact; cannot publish.
scripts/release.sh 0.2.0 --prepare-only --skip-notarization

# Publish the tag but keep the GitHub Release as a draft.
scripts/release.sh 0.2.0 --draft
```

See [docs/releasing.md](docs/releasing.md) for the full checklist and future auto-update notes.

## Authentication and privacy

The app discovers Timen's protected-resource and authorization-server metadata, dynamically registers a loopback redirect, and performs Authorization Code + PKCE in the system browser. Timen's page handles Google or email/password. TimenBar receives only the callback code and stores tokens and registration data in Keychain. It never embeds a credential form, copies browser cookies, or calls private Rails endpoints.

See [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), and [docs/architecture.md](docs/architecture.md).

## Status

This repository is a functional pre-release client foundation. Real-account acceptance tests are intentionally opt-in because they create and delete Timen data. Developer ID signing is configured, and public builds should go through the notarized release process above. A Sparkle EdDSA key and GitHub Pages appcast are only required when auto-updates are enabled later.

## License

MIT. See [LICENSE](LICENSE).
