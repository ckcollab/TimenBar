# Architecture

`AppModel` is the main-actor state coordinator used by SwiftUI. `TimenGateway` is the domain-facing async interface; `TimenMCPGateway` maps it to the required Timen MCP tools and validates `tools/list` before use. MCP wire values never escape the gateway.

OAuth is a native public-client flow with discovery, dynamic registration, loopback callback, state validation, PKCE S256, refresh, revocation, and Keychain-only secret storage.

SwiftData persists remote caches and local-only favorites, active timer segments, ordered outbox mutations, and conflicts. UI actions update the cache before network work. Replay proceeds by sequence, reconciles ambiguous responses by re-reading Timen, and sends anything not provably identical to Conflict Review.

Idle detection uses `CGEventSource.secondsSinceLastEventType` plus workspace sleep, wake, and session notifications. The timer continues while the decision sheet is open.

The app has two status items: a SwiftUI `MenuBarExtra` opens the panel, while a small AppKit-backed item provides a genuine one-click play/pause target. This bridge is necessary because a `MenuBarExtra` label is a single click target.
