# Architecture

`AppModel` is the main-actor state coordinator used by SwiftUI. `TimenGateway` is the domain-facing async interface; `TimenMCPGateway` maps it to the required Timen MCP tools and validates `tools/list` before use. MCP wire values never escape the gateway.

OAuth is a native public-client flow with discovery, dynamic registration, loopback callback, state validation, PKCE S256, refresh, revocation, and Keychain-only secret storage.

SwiftData persists server-backed project, tag, and entry caches, local favorite-project choices, and the active remote timer or continuation segment. The cache is bound to one Timen account; logout or a detected account change clears all account-owned records before another account can use it. Mutating UI actions require connectivity and update Timen before the local cache. No mutations are queued or replayed while offline; reconnecting refreshes the server-backed cache.

Idle detection uses `CGEventSource.secondsSinceLastEventType` plus workspace sleep, wake, and session notifications. The timer continues while the decision sheet is open.

The app has two status items: a SwiftUI `MenuBarExtra` opens the panel, while a small AppKit-backed item provides a genuine one-click play/pause target. This bridge is necessary because a `MenuBarExtra` label is a single click target.

## Time-entry behavior

Starting, stopping, editing, continuing, and deleting time require an active Timen connection. TimenBar does not queue changes while offline; cached projects, tags, and entries remain available for reference.

All time started or edited in TimenBar is submitted as billable. Editing an existing non-billable entry in TimenBar will make that entry billable.

## Authentication and privacy

The app discovers Timen's protected-resource and authorization-server metadata, dynamically registers a loopback redirect, and performs Authorization Code + PKCE in the system browser. Timen's page handles Google or email/password. TimenBar receives only the callback code and stores tokens and registration data in Keychain. It never embeds a credential form, copies browser cookies, or calls private Rails endpoints.

See [PRIVACY.md](../PRIVACY.md) and [SECURITY.md](../SECURITY.md).

## Building

Requirements:

- macOS 14 or newer
- Xcode 16.3 or newer (the project is configured for Swift 6 strict concurrency)
- A Timen account with access to the published MCP integration
- ImageMagick only when regenerating icon PNGs

```sh
./scripts/bootstrap.sh
open TimenBar.xcodeproj
```

Choose the `TimenBar` scheme and Run. The app is an `LSUIElement` accessory app, so it appears only in the menu bar. The main status item opens the weekly panel; the adjacent play/pause item restarts the most recent timer or stops the running timer.

The project pins the official Swift MCP SDK to `0.12.1` and Sparkle to `2.9.2`.
