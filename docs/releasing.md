# Releasing

Public releases require a Developer ID Application identity, hardened runtime, Apple notarization credentials, and a Sparkle EdDSA keypair. Put private material only in repository secrets.

Configure `SUFeedURL` for the GitHub Pages appcast and `SUPublicEDKey` for the Sparkle public key. The release workflow archives and exports the app, creates ZIP and DMG artifacts, submits the ZIP for notarization, staples the app and DMG, computes SHA-256 checksums, signs the Sparkle archive, updates the appcast, and uploads artifacts to the GitHub Release.

Before tagging, run unit and UI tests, perform the opt-in disposable-account scenario, and verify the prior release upgrades to the candidate through Sparkle. On a clean macOS 14 machine verify Gatekeeper, the stapled ticket, OAuth callback, launch at login, menu-bar controls, notifications, and sign-out revocation.
