import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct OAuthTokenSet: Codable, Sendable {
    var accessToken: String
    var tokenType: String
    var refreshToken: String?
    var scope: String?
    var expiresAt: Date?

    var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

struct OAuthClientRegistration: Codable, Sendable {
    var clientID: String
    var redirectURI: URL
}

struct OAuthProtocolError: LocalizedError, Sendable {
    var code: String
    var detail: String?

    var errorDescription: String? {
        if let detail, !detail.isEmpty { return detail }
        return code.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var invalidatesClientRegistration: Bool {
        switch code.lowercased() {
        case "invalid_client", "unauthorized_client", "invalid_redirect_uri", "redirect_uri_mismatch":
            true
        case "invalid_request", "invalid_grant":
            detail?.localizedCaseInsensitiveContains("redirect") == true
        default:
            false
        }
    }
}

enum OAuthSecurity {
    static func validateCallback(_ url: URL, expectedState: String) throws -> String {
        guard let callback = URLComponents(url: url, resolvingAgainstBaseURL: false),
              callback.queryItems?.first(where: { $0.name == "state" })?.value == expectedState
        else { throw TimenBarError.oauth("The callback state did not match.") }
        if let error = callback.queryItems?.first(where: { $0.name == "error" })?.value {
            let detail = callback.queryItems?.first(where: { $0.name == "error_description" })?.value
            throw OAuthProtocolError(code: error, detail: detail)
        }
        guard let code = callback.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw TimenBarError.oauth("The callback did not contain an authorization code.")
        }
        return code
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

enum OAuthCallbackPage {
    static let successHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta name="color-scheme" content="light dark">
      <title>TimenBar authorization received</title>
      <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1024 1024'%3E%3Cdefs%3E%3ClinearGradient id='bg' x1='128' y1='96' x2='896' y2='928' gradientUnits='userSpaceOnUse'%3E%3Cstop stop-color='%23FF8B3D'/%3E%3Cstop offset='1' stop-color='%23E43E55'/%3E%3C/linearGradient%3E%3C/defs%3E%3Crect x='48' y='48' width='928' height='928' rx='224' fill='url(%23bg)'/%3E%3Ccircle cx='512' cy='512' r='298' fill='%23FFF' fill-opacity='.14'/%3E%3Cpath d='M363 292h298M363 732h298' fill='none' stroke='%23FFF' stroke-width='58' stroke-linecap='round'/%3E%3Cpath d='M398 323c0 105 46 137 114 189-68 52-114 84-114 189h228c0-105-46-137-114-189 68-52 114-84 114-189H398Z' fill='%23FFF'/%3E%3Cpath d='M454 374h116c-8 44-28 65-58 90-30-25-50-46-58-90Zm58 184c33 26 56 51 62 91H450c6-40 29-65 62-91Z' fill='%23EF5260'/%3E%3C/svg%3E">
      <style>
        :root {
          color-scheme: light dark;
          --canvas: #f5f5f7;
          --card: rgba(255, 255, 255, .88);
          --text: #19191d;
          --secondary: #65656d;
          --border: rgba(25, 25, 29, .10);
          --rule: rgba(25, 25, 29, .09);
          --pill: rgba(228, 62, 85, .10);
          --pill-text: #b92c42;
          --shadow: 0 24px 70px rgba(69, 31, 39, .16);
        }

        @media (prefers-color-scheme: dark) {
          :root {
            --canvas: #16161a;
            --card: rgba(35, 35, 40, .92);
            --text: #fafafd;
            --secondary: #aaaab2;
            --border: rgba(255, 255, 255, .10);
            --rule: rgba(255, 255, 255, .08);
            --pill: rgba(239, 82, 96, .14);
            --pill-text: #ff8993;
            --shadow: 0 28px 80px rgba(0, 0, 0, .40);
          }
        }

        * { box-sizing: border-box; }

        body {
          min-height: 100vh;
          margin: 0;
          display: grid;
          place-items: center;
          padding: 32px;
          background:
            radial-gradient(circle at 50% -12%, rgba(255, 139, 61, .22), transparent 42%),
            radial-gradient(circle at 100% 100%, rgba(228, 62, 85, .10), transparent 38%),
            var(--canvas);
          color: var(--text);
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
          -webkit-font-smoothing: antialiased;
        }

        main {
          width: min(100%, 448px);
          padding: 44px 42px 38px;
          text-align: center;
          background: var(--card);
          border: 1px solid var(--border);
          border-radius: 28px;
          box-shadow: var(--shadow);
          backdrop-filter: blur(22px);
          -webkit-backdrop-filter: blur(22px);
        }

        .logo {
          display: block;
          width: 92px;
          height: 92px;
          margin: 0 auto 24px;
          filter: drop-shadow(0 12px 22px rgba(116, 34, 57, .22));
        }

        .status {
          display: inline-flex;
          align-items: center;
          gap: 7px;
          padding: 7px 11px;
          color: var(--pill-text);
          background: var(--pill);
          border-radius: 999px;
          font-size: 13px;
          font-weight: 650;
          letter-spacing: .01em;
        }

        .check {
          display: grid;
          width: 17px;
          height: 17px;
          place-items: center;
          border: 1.5px solid currentColor;
          border-radius: 50%;
          font-size: 11px;
          line-height: 1;
        }

        h1 {
          margin: 17px 0 10px;
          font-size: clamp(28px, 7vw, 33px);
          font-weight: 700;
          letter-spacing: -.035em;
          line-height: 1.12;
        }

        p {
          max-width: 34ch;
          margin: 0 auto;
          color: var(--secondary);
          font-size: 16px;
          line-height: 1.55;
        }

        .hint {
          margin-top: 26px;
          padding-top: 22px;
          border-top: 1px solid var(--rule);
          font-size: 14px;
        }

        @media (max-width: 520px) {
          body { padding: 18px; }
          main { padding: 36px 24px 30px; border-radius: 23px; }
          .logo { width: 82px; height: 82px; }
        }
      </style>
    </head>
    <body>
      <main aria-labelledby="title">
        <svg class="logo" aria-hidden="true" focusable="false" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
          <defs>
            <linearGradient id="logo-gradient" x1="128" y1="96" x2="896" y2="928" gradientUnits="userSpaceOnUse">
              <stop stop-color="#FF8B3D"/>
              <stop offset="1" stop-color="#E43E55"/>
            </linearGradient>
            <filter id="logo-shadow" x="-20%" y="-20%" width="140%" height="140%">
              <feDropShadow dx="0" dy="28" stdDeviation="28" flood-color="#742239" flood-opacity=".32"/>
            </filter>
          </defs>
          <rect x="48" y="48" width="928" height="928" rx="224" fill="url(#logo-gradient)"/>
          <circle cx="512" cy="512" r="298" fill="#FFF" fill-opacity=".14"/>
          <path d="M363 292h298M363 732h298" fill="none" stroke="#FFF" stroke-width="58" stroke-linecap="round"/>
          <path d="M398 323c0 105 46 137 114 189-68 52-114 84-114 189h228c0-105-46-137-114-189 68-52 114-84 114-189H398Z" fill="#FFF" filter="url(#logo-shadow)"/>
          <path d="M454 374h116c-8 44-28 65-58 90-30-25-50-46-58-90Zm58 184c33 26 56 51 62 91H450c6-40 29-65 62-91Z" fill="#EF5260"/>
        </svg>
        <div class="status"><span class="check" aria-hidden="true">✓</span>Secure sign-in</div>
        <h1 id="title">Authorization received</h1>
        <p>Return to TimenBar to finish connecting to Timen.</p>
        <p class="hint">You can safely close this tab.</p>
      </main>
    </body>
    </html>
    """

    static func successResponse() -> Data {
        let contentLength = successHTML.utf8.count
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(contentLength)",
            "Cache-Control: no-store",
            "Pragma: no-cache",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            "X-Content-Type-Options: nosniff",
            "Referrer-Policy: no-referrer",
            "X-Frame-Options: DENY",
            "Cross-Origin-Resource-Policy: same-origin",
            "Connection: close",
        ].joined(separator: "\r\n")
        return Data((headers + "\r\n\r\n" + successHTML).utf8)
    }
}

private struct ProtectedResourceMetadata: Decodable {
    var resource: URL
    var authorizationServers: [URL]
    var scopesSupported: [String]

    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

private struct AuthorizationServerMetadata: Decodable {
    var issuer: URL
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var revocationEndpoint: URL?
    var registrationEndpoint: URL
    var codeChallengeMethodsSupported: [String]

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case revocationEndpoint = "revocation_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
    }
}

private struct RegistrationResponse: Decodable {
    var clientID: String

    enum CodingKeys: String, CodingKey { case clientID = "client_id" }
}

private struct TokenResponse: Decodable {
    var accessToken: String
    var tokenType: String
    var expiresIn: TimeInterval?
    var refreshToken: String?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

actor OAuthSession {
    static let resourceURL = URL(string: "https://mcp.gettimen.com/mcp")!
    static let resourceMetadataURL = URL(string: "https://mcp.gettimen.com/.well-known/oauth-protected-resource")!

    private let session: URLSession
    private let keychain: KeychainStore
    private let callbackServerFactory: @Sendable () -> any OAuthCallbackServing
    private let openAuthorizationURL: @Sendable (URL) async -> Bool
    private let callbackTimeout: Duration
    private let tokenAccount = "tokens"
    private let registrationAccount = "registration"
    private var cachedTokens: OAuthTokenSet?
    private var didLoadTokens = false
    private var cachedRegistration: OAuthClientRegistration?
    private var didLoadRegistration = false

    init(
        session: URLSession = .shared,
        keychain: KeychainStore = .shared,
        callbackServerFactory: @escaping @Sendable () -> any OAuthCallbackServing = { LoopbackCallbackServer() },
        openAuthorizationURL: @escaping @Sendable (URL) async -> Bool = { url in
            await MainActor.run { NSWorkspace.shared.open(url) }
        },
        callbackTimeout: Duration = .seconds(180)
    ) {
        self.session = session
        self.keychain = keychain
        self.callbackServerFactory = callbackServerFactory
        self.openAuthorizationURL = openAuthorizationURL
        self.callbackTimeout = callbackTimeout
    }

    func isAuthenticated() async -> Bool {
        (try? await storedTokens()) != nil
    }

    func authenticate() async throws {
        let resource = try await fetch(ProtectedResourceMetadata.self, from: Self.resourceMetadataURL)
        guard let issuer = resource.authorizationServers.first else {
            throw TimenBarError.oauth("Timen did not advertise an authorization server.")
        }
        let metadataURL = issuer.appending(path: ".well-known/oauth-authorization-server")
        let metadata = try await fetch(AuthorizationServerMetadata.self, from: metadataURL)
        guard metadata.codeChallengeMethodsSupported.contains("S256") else {
            throw TimenBarError.oauth("Timen does not advertise the required PKCE S256 method.")
        }

        let hadSavedRegistration = try await storedRegistration() != nil

        do {
            try await authenticate(
                resource: resource,
                metadata: metadata,
                forceNewRegistration: false
            )
        } catch let error as OAuthProtocolError where hadSavedRegistration && error.invalidatesClientRegistration {
            try await deleteRegistration()
            try await authenticate(
                resource: resource,
                metadata: metadata,
                forceNewRegistration: true
            )
        }
    }

    private func authenticate(
        resource: ProtectedResourceMetadata,
        metadata: AuthorizationServerMetadata,
        forceNewRegistration: Bool
    ) async throws {
        let callbackServer = callbackServerFactory()
        let redirectURI = try await callbackServer.start()
        defer { callbackServer.stop() }

        let registration = try await clientRegistration(
            for: redirectURI,
            at: metadata.registrationEndpoint,
            forceNew: forceNewRegistration
        )

        let verifier = Self.randomBase64URL(byteCount: 48)
        let challenge = OAuthSecurity.challenge(for: verifier)
        let state = Self.randomBase64URL(byteCount: 32)

        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: registration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: "read write offline_access"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resource.resource.absoluteString),
        ]
        guard let authorizationURL = components?.url else { throw TimenBarError.oauth("Unable to form the authorization URL.") }

        let opened = await openAuthorizationURL(authorizationURL)
        guard opened else { throw TimenBarError.oauth("The system browser could not be opened.") }

        let callbackURL = try await callbackServer.waitForCallback(timeout: callbackTimeout)
        let code = try OAuthSecurity.validateCallback(callbackURL, expectedState: state)

        let tokens = try await exchangeCode(
            code,
            verifier: verifier,
            registration: registration,
            tokenEndpoint: metadata.tokenEndpoint,
            resource: resource.resource
        )
        try Task.checkCancellation()
        try await saveTokens(tokens)
    }

    func accessToken() async throws -> String {
        guard var tokens = try await storedTokens() else {
            throw TimenBarError.notAuthenticated
        }
        if tokens.needsRefresh {
            tokens = try await refresh(tokens)
            try await saveTokens(tokens)
        }
        return tokens.accessToken
    }

    func signOut() async throws {
        let tokens = try await storedTokens()
        try await deleteTokens()

        guard let tokens else { return }
        Task { [weak self] in
            await self?.revoke(tokens)
        }
    }

    private func revoke(_ tokens: OAuthTokenSet) async {
        guard let metadata = try? await authorizationMetadata(),
              let endpoint = metadata.revocationEndpoint,
              let registration = try? await storedRegistration()
        else { return }

        for token in [tokens.accessToken, tokens.refreshToken].compactMap({ $0 }) {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formData(["token": token, "client_id": registration.clientID])
            _ = try? await session.data(for: request)
        }
    }

    private func authorizationMetadata() async throws -> AuthorizationServerMetadata {
        let resource = try await fetch(ProtectedResourceMetadata.self, from: Self.resourceMetadataURL)
        guard let issuer = resource.authorizationServers.first else { throw TimenBarError.oauth("Missing issuer") }
        return try await fetch(AuthorizationServerMetadata.self, from: issuer.appending(path: ".well-known/oauth-authorization-server"))
    }

    func clientRegistration(
        for redirectURI: URL,
        at endpoint: URL,
        forceNew: Bool = false
    ) async throws -> OAuthClientRegistration {
        if !forceNew,
           let saved = try await storedRegistration()
        {
            let registration = OAuthClientRegistration(clientID: saved.clientID, redirectURI: redirectURI)
            try await saveRegistration(registration)
            return registration
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "client_name": "TimenBar",
            "application_type": "native",
            "redirect_uris": [redirectURI.absoluteString],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": "read write offline_access",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response: RegistrationResponse = try await send(request)
        let registration = OAuthClientRegistration(clientID: response.clientID, redirectURI: redirectURI)
        try await saveRegistration(registration)
        return registration
    }

    private func exchangeCode(
        _ code: String,
        verifier: String,
        registration: OAuthClientRegistration,
        tokenEndpoint: URL,
        resource: URL
    ) async throws -> OAuthTokenSet {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formData([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": registration.clientID,
            "redirect_uri": registration.redirectURI.absoluteString,
            "code_verifier": verifier,
            "resource": resource.absoluteString,
        ])
        return try await tokenSet(from: request)
    }

    private func refresh(_ current: OAuthTokenSet) async throws -> OAuthTokenSet {
        guard let refreshToken = current.refreshToken,
              let registration = try await storedRegistration()
        else { throw TimenBarError.notAuthenticated }
        let resource = try await fetch(ProtectedResourceMetadata.self, from: Self.resourceMetadataURL)
        let metadata = try await authorizationMetadata()
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formData([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": registration.clientID,
            "resource": resource.resource.absoluteString,
        ])
        var refreshed = try await tokenSet(from: request)
        if refreshed.refreshToken == nil { refreshed.refreshToken = current.refreshToken }
        return refreshed
    }

    private func storedTokens() async throws -> OAuthTokenSet? {
        if didLoadTokens { return cachedTokens }
        let tokens = try await keychain.load(OAuthTokenSet.self, account: tokenAccount)
        cachedTokens = tokens
        didLoadTokens = true
        return tokens
    }

    private func saveTokens(_ tokens: OAuthTokenSet) async throws {
        try await keychain.save(tokens, account: tokenAccount)
        cachedTokens = tokens
        didLoadTokens = true
    }

    private func deleteTokens() async throws {
        cachedTokens = nil
        didLoadTokens = true
        try await keychain.delete(account: tokenAccount)
    }

    private func storedRegistration() async throws -> OAuthClientRegistration? {
        if didLoadRegistration { return cachedRegistration }
        let registration = try await keychain.load(
            OAuthClientRegistration.self,
            account: registrationAccount
        )
        cachedRegistration = registration
        didLoadRegistration = true
        return registration
    }

    private func saveRegistration(_ registration: OAuthClientRegistration) async throws {
        try await keychain.save(registration, account: registrationAccount)
        cachedRegistration = registration
        didLoadRegistration = true
    }

    private func deleteRegistration() async throws {
        cachedRegistration = nil
        didLoadRegistration = true
        try await keychain.delete(account: registrationAccount)
    }

    private func tokenSet(from request: URLRequest) async throws -> OAuthTokenSet {
        let response: TokenResponse = try await send(request)
        return OAuthTokenSet(
            accessToken: response.accessToken,
            tokenType: response.tokenType,
            refreshToken: response.refreshToken,
            scope: response.scope,
            expiresAt: response.expiresIn.map { .now.addingTimeInterval($0) }
        )
    }

    private func fetch<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        try await send(URLRequest(url: url))
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            if let oauthError = try? JSONDecoder().decode(OAuthErrorResponse.self, from: data) {
                throw OAuthProtocolError(code: oauthError.error, detail: oauthError.errorDescription)
            }
            let detail = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw TimenBarError.oauth(detail)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw TimenBarError.invalidResponse(error.localizedDescription) }
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return OAuthSecurity.base64URL(Data(bytes))
    }

    private static func formData(_ fields: [String: String]) -> Data {
        fields
            .map { key, value in "\(key.urlFormEncoded)=\(value.urlFormEncoded)" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }
}

private struct OAuthErrorResponse: Decodable {
    var error: String
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self
    }
}

protocol OAuthCallbackServing: Sendable {
    func start() async throws -> URL
    func waitForCallback(timeout: Duration) async throws -> URL
    func stop()
}

final class LoopbackCallbackServer: OAuthCallbackServing, @unchecked Sendable {
    typealias Sleep = @Sendable (Duration) async throws -> Void
    typealias ListenerFactory = @Sendable () throws -> NWListener

    private let queue = DispatchQueue(label: "app.timenbar.oauth-loopback")
    private let sleep: Sleep
    private let makeListener: ListenerFactory
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallback: Result<URL, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var callbackFinished = false
    private var stopped = false

    init(
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) },
        makeListener: @escaping ListenerFactory = {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            return try NWListener(using: parameters)
        }
    ) {
        self.sleep = sleep
        self.makeListener = makeListener
    }

    func start() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.stopped else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.readyContinuation = continuation
                    do {
                        let listener = try self.makeListener()
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                        listener.start(queue: self.queue)
                    } catch {
                        self.finishAll(.failure(error))
                    }
                }
            }
        } onCancel: {
            queue.async { self.finishAll(.failure(CancellationError())) }
        }
    }

    func waitForCallback(timeout: Duration) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.stopped else {
                        let result = self.pendingCallback ?? .failure(CancellationError())
                        self.pendingCallback = nil
                        continuation.resume(with: result)
                        return
                    }
                    self.callbackContinuation = continuation
                    let sleep = self.sleep
                    self.timeoutTask = Task { [weak self] in
                        do {
                            try await sleep(timeout)
                        } catch {
                            return
                        }
                        guard let self else { return }
                        self.queue.async {
                            self.finishCallback(.failure(TimenBarError.oauth("Sign-in timed out.")))
                        }
                    }
                }
            }
        } onCancel: {
            queue.async {
                self.finishCallback(.failure(CancellationError()))
            }
        }
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback")
            else {
                finishAll(.failure(TimenBarError.oauth("The sign-in listener did not provide a local port.")))
                return
            }
            finishStart(.success(url))
        case let .failed(error):
            finishAll(.failure(error))
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.finishCallback(.failure(error))
                connection.cancel()
                return
            }
            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.components(separatedBy: "\r\n").first,
                  requestLine.hasPrefix("GET "),
                  let path = requestLine.split(separator: " ").dropFirst().first,
                  let port = self.listener?.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(path)"),
                  url.path == "/oauth/callback"
            else {
                connection.cancel()
                return
            }

            connection.send(
                content: OAuthCallbackPage.successResponse(),
                completion: .contentProcessed { _ in connection.cancel() }
            )

            self.finishCallback(.success(url))
        }
    }

    func stop() {
        queue.async {
            self.finishAll(.failure(CancellationError()))
        }
    }

    private func finishStart(_ result: Result<URL, Error>) {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        continuation.resume(with: result)
    }

    private func finishCallback(_ result: Result<URL, Error>) {
        guard !callbackFinished else { return }
        callbackFinished = true
        let continuation = callbackContinuation
        callbackContinuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        stopped = true
        listener?.cancel()
        listener = nil

        if let continuation {
            continuation.resume(with: result)
        } else {
            pendingCallback = result
        }
    }

    private func finishAll(_ result: Result<URL, Error>) {
        finishStart(result)
        finishCallback(result)
    }
}
