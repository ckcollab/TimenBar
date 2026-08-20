# Privacy

TimenBar stores OAuth tokens and dynamic client registration in the macOS Keychain. Timen account details (ID, name, email, team, role, and time zone), projects, tags, time entries, favorite project choices, and active remote timer or continuation metadata (start time, project, tags, and notes) are cached locally with SwiftData. This cache is bound to one Timen account and is cleared on logout or account change. Cached Timen data can be viewed without a connection, but TimenBar does not queue offline changes.

The app sends data only to Timen's documented OAuth and MCP services and, when enabled for a signed release, the configured Sparkle appcast host. Idle detection reads the system's elapsed time since the last input event; it does not record keys, pointer positions, application names, window titles, screenshots, or screen contents.

TimenBar requests outbound networking and loopback-server access for OAuth. It does not request Accessibility, screen recording, microphone, camera, contacts, or location permission.
