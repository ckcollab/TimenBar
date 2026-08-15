# Privacy

TimenBar stores OAuth tokens and dynamic client registration in the macOS Keychain. Projects, tags, time entries, favorites, pending timer segments, sync mutations, and conflict summaries are cached locally with SwiftData so the app can work offline.

The app sends data only to Timen's documented OAuth and MCP services and, when enabled for a signed release, the configured Sparkle appcast host. Idle detection reads the system's elapsed time since the last input event; it does not record keys, pointer positions, application names, window titles, screenshots, or screen contents.

TimenBar requests outbound networking and loopback-server access for OAuth. It does not request Accessibility, screen recording, microphone, camera, contacts, or location permission.
