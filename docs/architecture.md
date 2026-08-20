# Architecture

`AppModel` is the main-actor state coordinator used by SwiftUI. `TimenGateway` is the domain-facing async interface; `TimenMCPGateway` maps it to the required Timen MCP tools and validates `tools/list` before use. MCP wire values never escape the gateway.

OAuth is a native public-client flow with discovery, dynamic registration, loopback callback, state validation, PKCE S256, refresh, revocation, and Keychain-only secret storage.

SwiftData persists server-backed project, tag, and entry caches, local favorite-project choices, and the active remote timer or continuation segment. The cache is bound to one Timen account; logout or a detected account change clears all account-owned records before another account can use it. Mutating UI actions require connectivity and update Timen before the local cache. No mutations are queued or replayed while offline; reconnecting refreshes the server-backed cache.

Idle detection uses `CGEventSource.secondsSinceLastEventType` plus workspace sleep, wake, and session notifications. The timer continues while the decision sheet is open.

The app has two status items: a SwiftUI `MenuBarExtra` opens the panel, while a small AppKit-backed item provides a genuine one-click play/pause target. This bridge is necessary because a `MenuBarExtra` label is a single click target.
