# TimenBar

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

## Authentication and privacy

The app discovers Timen's protected-resource and authorization-server metadata, dynamically registers a loopback redirect, and performs Authorization Code + PKCE in the system browser. Timen's page handles Google or email/password. TimenBar receives only the callback code and stores tokens and registration data in Keychain. It never embeds a credential form, copies browser cookies, or calls private Rails endpoints.

See [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), and [docs/architecture.md](docs/architecture.md).

## Status

This repository is a functional pre-release client foundation. Real-account acceptance tests are intentionally opt-in because they create and delete Timen data. Before public distribution, configure signing, notarization, the Sparkle EdDSA key and GitHub Pages appcast, then review Timen's current terms for the intended distribution model.

## License

MIT. See [LICENSE](LICENSE).
