# Security

Please report a vulnerability privately to the repository maintainers rather than opening a public issue containing credentials or exploit details.

Never attach Timen access tokens, refresh tokens, OAuth authorization codes, Keychain exports, Apple signing certificates, notarization passwords, or Sparkle private keys to an issue. Release credentials belong only in GitHub Actions secrets.

The supported integration boundary is Timen's published OAuth/MCP service. Session-cookie extraction, embedded Timen password fields, and private web endpoints are out of scope.
