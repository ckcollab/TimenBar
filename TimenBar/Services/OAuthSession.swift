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

enum OAuthSecurity {
    static func validateCallback(_ url: URL, expectedState: String) throws -> String {
        guard let callback = URLComponents(url: url, resolvingAgainstBaseURL: false),
              callback.queryItems?.first(where: { $0.name == "state" })?.value == expectedState
        else { throw TimenBarError.oauth("The callback state did not match.") }
        if let error = callback.queryItems?.first(where: { $0.name == "error" })?.value {
            throw TimenBarError.oauth(error)
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
    private let tokenAccount = "tokens"
    private let registrationAccount = "registration"

    init(session: URLSession = .shared, keychain: KeychainStore = .shared) {
        self.session = session
        self.keychain = keychain
    }

    func isAuthenticated() async -> Bool {
        (try? await keychain.load(OAuthTokenSet.self, account: tokenAccount)) != nil
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

        let callbackServer = LoopbackCallbackServer()
        let redirectURI = try await callbackServer.start()
        let registration = try await registerClient(at: metadata.registrationEndpoint, redirectURI: redirectURI)
        try await keychain.save(registration, account: registrationAccount)

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

        let opened = await MainActor.run { NSWorkspace.shared.open(authorizationURL) }
        guard opened else { throw TimenBarError.oauth("The system browser could not be opened.") }

        let callbackURL = try await callbackServer.waitForCallback(timeout: .seconds(180))
        let code = try OAuthSecurity.validateCallback(callbackURL, expectedState: state)

        let tokens = try await exchangeCode(
            code,
            verifier: verifier,
            registration: registration,
            tokenEndpoint: metadata.tokenEndpoint,
            resource: resource.resource
        )
        try await keychain.save(tokens, account: tokenAccount)
    }

    func accessToken() async throws -> String {
        guard var tokens = try await keychain.load(OAuthTokenSet.self, account: tokenAccount) else {
            throw TimenBarError.notAuthenticated
        }
        if tokens.needsRefresh {
            tokens = try await refresh(tokens)
            try await keychain.save(tokens, account: tokenAccount)
        }
        return tokens.accessToken
    }

    func signOut() async throws {
        if let tokens = try await keychain.load(OAuthTokenSet.self, account: tokenAccount),
           let metadata = try? await authorizationMetadata()
        {
            if let endpoint = metadata.revocationEndpoint,
               let registration = try? await keychain.load(OAuthClientRegistration.self, account: registrationAccount)
            {
                for token in [tokens.accessToken, tokens.refreshToken].compactMap({ $0 }) {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    request.httpBody = Self.formData(["token": token, "client_id": registration.clientID])
                    _ = try? await session.data(for: request)
                }
            }
        }
        try await keychain.delete(account: tokenAccount)
        try await keychain.delete(account: registrationAccount)
    }

    private func authorizationMetadata() async throws -> AuthorizationServerMetadata {
        let resource = try await fetch(ProtectedResourceMetadata.self, from: Self.resourceMetadataURL)
        guard let issuer = resource.authorizationServers.first else { throw TimenBarError.oauth("Missing issuer") }
        return try await fetch(AuthorizationServerMetadata.self, from: issuer.appending(path: ".well-known/oauth-authorization-server"))
    }

    private func registerClient(at endpoint: URL, redirectURI: URL) async throws -> OAuthClientRegistration {
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
        return OAuthClientRegistration(clientID: response.clientID, redirectURI: redirectURI)
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
              let registration = try await keychain.load(OAuthClientRegistration.self, account: registrationAccount)
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

private extension String {
    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self
    }
}

private final class LoopbackCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.timenbar.oauth-loopback")
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallback: URL?

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    self.readyContinuation = continuation
                    listener.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.start(queue: self.queue)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func waitForCallback(timeout: Duration) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.queue.async {
                        if let pending = self.pendingCallback {
                            continuation.resume(returning: pending)
                        } else {
                            self.callbackContinuation = continuation
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TimenBarError.oauth("Sign-in timed out.")
            }
            guard let result = try await group.next() else { throw TimenBarError.oauth("Sign-in was cancelled.") }
            group.cancelAll()
            stop()
            return result
        }
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback")
            else { return }
            readyContinuation?.resume(returning: url)
            readyContinuation = nil
        case let .failed(error):
            readyContinuation?.resume(throwing: error)
            callbackContinuation?.resume(throwing: error)
            readyContinuation = nil
            callbackContinuation = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.callbackContinuation?.resume(throwing: error)
                self.callbackContinuation = nil
                connection.cancel()
                return
            }
            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.components(separatedBy: "\r\n").first,
                  requestLine.hasPrefix("GET "),
                  let path = requestLine.split(separator: " ").dropFirst().first,
                  let port = self.listener?.port,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(path)")
            else {
                connection.cancel()
                return
            }

            let html = """
            <!doctype html><meta charset="utf-8"><title>TimenBar connected</title>
            <body style="font-family:-apple-system;padding:3rem"><h1>Connected to TimenBar</h1>
            <p>You can close this window and return to TimenBar.</p></body>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })

            if let continuation = self.callbackContinuation {
                self.callbackContinuation = nil
                continuation.resume(returning: url)
            } else {
                self.pendingCallback = url
            }
        }
    }

    private func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
        }
    }
}
