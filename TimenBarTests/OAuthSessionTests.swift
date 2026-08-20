import Foundation
import Network
import XCTest
@testable import TimenBar

final class OAuthSessionTests: XCTestCase {
    func testLoopbackTimeoutResumesWithoutAWebCallback() async throws {
        let server = LoopbackCallbackServer(sleep: { _ in })
        _ = try await server.start()

        do {
            _ = try await server.waitForCallback(timeout: .seconds(180))
            XCTFail("Expected the callback wait to time out")
        } catch let error as TimenBarError {
            guard case let .oauth(message) = error else {
                return XCTFail("Unexpected TimenBar error: \(error)")
            }
            XCTAssertEqual(message, "Sign-in timed out.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testLoopbackStartFailureResumesTheContinuation() async {
        let server = LoopbackCallbackServer(makeListener: { throw OAuthTestError.listenerCreationFailed })

        do {
            _ = try await server.start()
            XCTFail("Expected listener creation to fail")
        } catch OAuthTestError.listenerCreationFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellingCallbackWaitResumesTheContinuation() async throws {
        let server = LoopbackCallbackServer()
        _ = try await server.start()
        let wait = Task {
            try await server.waitForCallback(timeout: .seconds(30))
        }

        await Task.yield()
        wait.cancel()

        do {
            _ = try await wait.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellingStartWhileListenerIsBeingCreatedResumesExactlyOnce() async {
        let factoryEntered = DispatchSemaphore(value: 0)
        let releaseFactory = DispatchSemaphore(value: 0)
        let server = LoopbackCallbackServer(makeListener: {
            factoryEntered.signal()
            releaseFactory.wait()

            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            return try NWListener(using: parameters)
        })
        let start = Task { try await server.start() }

        XCTAssertEqual(factoryEntered.wait(timeout: .now() + 2), .success)
        start.cancel()
        releaseFactory.signal()

        do {
            _ = try await start.value
            XCTFail("Expected listener start to be cancelled")
        } catch is CancellationError {
            // Expected. A double resume would fail at runtime.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        server.stop()
    }

    func testAuthenticateReRegistersAStaleClientAfterTokenExchangeRejectsIt() async throws {
        OAuthAuthenticateRequestRecorder.shared.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthAuthenticateURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let keychain = KeychainStore(service: "app.timenbar.tests.oauth.authenticate.\(UUID().uuidString)")
        addTeardownBlock {
            try await keychain.delete(account: "tokens")
            try await keychain.delete(account: "registration")
        }
        let oldRedirect = try XCTUnwrap(URL(string: "http://127.0.0.1:40999/oauth/callback"))
        try await keychain.save(
            OAuthClientRegistration(clientID: "stale-client", redirectURI: oldRedirect),
            account: "registration"
        )

        let flow = OAuthAuthenticateFlow()
        let oauth = OAuthSession(
            session: session,
            keychain: keychain,
            callbackServerFactory: { flow.makeCallbackServer() },
            openAuthorizationURL: { url in flow.openAuthorizationURL(url) },
            callbackTimeout: .seconds(1)
        )

        try await oauth.authenticate()

        let storedTokens = try await keychain.load(OAuthTokenSet.self, account: "tokens")
        let storedRegistration = try await keychain.load(OAuthClientRegistration.self, account: "registration")
        let accessToken = try await oauth.accessToken()
        let requests = OAuthAuthenticateRequestRecorder.shared.snapshot
        let authorizationRounds = flow.authorizationRounds

        XCTAssertEqual(storedTokens?.accessToken, "fresh-access-token")
        XCTAssertEqual(storedTokens?.refreshToken, "fresh-refresh-token")
        XCTAssertEqual(storedRegistration?.clientID, "fresh-client")
        XCTAssertEqual(storedRegistration?.redirectURI, flow.redirectURIs[1])
        XCTAssertEqual(requests.registrationRequestCount, 1)
        XCTAssertEqual(requests.registrationRedirectURIs, [flow.redirectURIs[1].absoluteString])
        XCTAssertEqual(requests.tokenClientIDs, ["stale-client", "fresh-client"])
        XCTAssertEqual(requests.tokenCodes, ["stale-code", "fresh-code"])
        XCTAssertEqual(authorizationRounds.map(\.clientID), ["stale-client", "fresh-client"])
        XCTAssertEqual(authorizationRounds.map(\.redirectURI), flow.redirectURIs.map(\.absoluteString))
        XCTAssertEqual(flow.stoppedServerIndices, Set([0, 1]))
        XCTAssertEqual(accessToken, "fresh-access-token")
    }

    func testSavedClientRegistrationIsReusedWithCurrentLoopbackURIAfterLogout() async throws {
        OAuthRequestRecorder.shared.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let keychain = KeychainStore(service: "app.timenbar.tests.oauth.\(UUID().uuidString)")
        addTeardownBlock {
            try await keychain.delete(account: "tokens")
            try await keychain.delete(account: "registration")
        }
        let oauth = OAuthSession(session: session, keychain: keychain)
        let endpoint = try XCTUnwrap(URL(string: "https://authorization.example/register"))
        let firstRedirect = try XCTUnwrap(URL(string: "http://127.0.0.1:41001/oauth/callback"))
        let secondRedirect = try XCTUnwrap(URL(string: "http://127.0.0.1:41002/oauth/callback"))
        let afterLogoutRedirect = try XCTUnwrap(URL(string: "http://127.0.0.1:41003/oauth/callback"))

        let first = try await oauth.clientRegistration(for: firstRedirect, at: endpoint)
        let second = try await oauth.clientRegistration(for: secondRedirect, at: endpoint)
        try await oauth.signOut()
        let afterLogout = try await oauth.clientRegistration(for: afterLogoutRedirect, at: endpoint)

        XCTAssertEqual(first.clientID, "registered-client")
        XCTAssertEqual(second.clientID, first.clientID)
        XCTAssertEqual(second.redirectURI, secondRedirect)
        XCTAssertEqual(afterLogout.clientID, first.clientID)
        XCTAssertEqual(afterLogout.redirectURI, afterLogoutRedirect)
        XCTAssertEqual(OAuthRequestRecorder.shared.registrationRequestCount, 1)
    }

    func testOnlyClientAndRedirectErrorsInvalidateRegistration() {
        XCTAssertTrue(OAuthProtocolError(code: "invalid_client", detail: nil).invalidatesClientRegistration)
        XCTAssertTrue(OAuthProtocolError(
            code: "invalid_grant",
            detail: "The redirect_uri does not match the registered value."
        ).invalidatesClientRegistration)
        XCTAssertFalse(OAuthProtocolError(code: "invalid_grant", detail: "Authorization code expired.").invalidatesClientRegistration)
        XCTAssertFalse(OAuthProtocolError(code: "access_denied", detail: nil).invalidatesClientRegistration)
    }

    func testAuthorizationCallbackPreservesProtocolErrorForRegistrationFallback() throws {
        let callback = try XCTUnwrap(URL(string:
            "http://127.0.0.1:4567/oauth/callback?error=invalid_client&error_description=Unknown%20client&state=expected"
        ))

        XCTAssertThrowsError(try OAuthSecurity.validateCallback(callback, expectedState: "expected")) { error in
            guard let oauthError = error as? OAuthProtocolError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(oauthError.code, "invalid_client")
            XCTAssertEqual(oauthError.detail, "Unknown client")
            XCTAssertTrue(oauthError.invalidatesClientRegistration)
        }
    }
}

private enum OAuthTestError: LocalizedError {
    case listenerCreationFailed
    case missingAuthorizationRound
    case unexpectedRequest(String)

    var errorDescription: String? {
        switch self {
        case .listenerCreationFailed:
            "Listener creation failed"
        case .missingAuthorizationRound:
            "The authorization URL was not recorded before the callback"
        case let .unexpectedRequest(detail):
            "Unexpected OAuth request: \(detail)"
        }
    }
}

private struct OAuthAuthorizationRound: Equatable, Sendable {
    let clientID: String
    let redirectURI: String
}

private final class OAuthAuthenticateFlow: @unchecked Sendable {
    let redirectURIs = [
        URL(string: "http://127.0.0.1:42001/oauth/callback")!,
        URL(string: "http://127.0.0.1:42002/oauth/callback")!,
    ]

    private let lock = NSLock()
    private var nextServerIndex = 0
    private var authorizationURLs: [URL] = []
    private var stoppedIndices: Set<Int> = []

    var authorizationRounds: [OAuthAuthorizationRound] {
        lock.withLock {
            authorizationURLs.map { url in
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                return OAuthAuthorizationRound(
                    clientID: query.first(where: { $0.name == "client_id" })?.value ?? "",
                    redirectURI: query.first(where: { $0.name == "redirect_uri" })?.value ?? ""
                )
            }
        }
    }

    var stoppedServerIndices: Set<Int> {
        lock.withLock { stoppedIndices }
    }

    func makeCallbackServer() -> any OAuthCallbackServing {
        let index = lock.withLock {
            defer { nextServerIndex += 1 }
            return nextServerIndex
        }
        return OAuthAuthenticateCallbackServer(
            index: index,
            redirectURI: redirectURIs[index],
            flow: self
        )
    }

    func openAuthorizationURL(_ url: URL) -> Bool {
        lock.withLock {
            authorizationURLs.append(url)
        }
        return true
    }

    func callbackURL(for index: Int, redirectURI: URL) throws -> URL {
        try lock.withLock {
            guard authorizationURLs.indices.contains(index),
                  let state = URLComponents(
                      url: authorizationURLs[index],
                      resolvingAgainstBaseURL: false
                  )?.queryItems?.first(where: { $0.name == "state" })?.value
            else { throw OAuthTestError.missingAuthorizationRound }

            var callback = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)
            callback?.queryItems = [
                URLQueryItem(name: "code", value: index == 0 ? "stale-code" : "fresh-code"),
                URLQueryItem(name: "state", value: state),
            ]
            guard let url = callback?.url else { throw OAuthTestError.missingAuthorizationRound }
            return url
        }
    }

    func recordStop(serverIndex: Int) {
        _ = lock.withLock {
            stoppedIndices.insert(serverIndex)
        }
    }
}

private final class OAuthAuthenticateCallbackServer: OAuthCallbackServing, @unchecked Sendable {
    private let index: Int
    private let redirectURI: URL
    private let flow: OAuthAuthenticateFlow

    init(index: Int, redirectURI: URL, flow: OAuthAuthenticateFlow) {
        self.index = index
        self.redirectURI = redirectURI
        self.flow = flow
    }

    func start() async throws -> URL {
        redirectURI
    }

    func waitForCallback(timeout _: Duration) async throws -> URL {
        try flow.callbackURL(for: index, redirectURI: redirectURI)
    }

    func stop() {
        flow.recordStop(serverIndex: index)
    }
}

private struct OAuthAuthenticateRequestSnapshot: Sendable {
    let registrationRequestCount: Int
    let registrationRedirectURIs: [String]
    let tokenClientIDs: [String]
    let tokenCodes: [String]
}

private final class OAuthAuthenticateRequestRecorder: @unchecked Sendable {
    static let shared = OAuthAuthenticateRequestRecorder()

    private let lock = NSLock()
    private var registrationRequestCount = 0
    private var registrationRedirectURIs: [String] = []
    private var tokenClientIDs: [String] = []
    private var tokenCodes: [String] = []

    var snapshot: OAuthAuthenticateRequestSnapshot {
        lock.withLock {
            OAuthAuthenticateRequestSnapshot(
                registrationRequestCount: registrationRequestCount,
                registrationRedirectURIs: registrationRedirectURIs,
                tokenClientIDs: tokenClientIDs,
                tokenCodes: tokenCodes
            )
        }
    }

    func reset() {
        lock.withLock {
            registrationRequestCount = 0
            registrationRedirectURIs = []
            tokenClientIDs = []
            tokenCodes = []
        }
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        guard let url = request.url else { throw OAuthTestError.unexpectedRequest("missing URL") }

        switch (request.httpMethod ?? "GET", url.host, url.path) {
        case ("GET", "mcp.gettimen.com", "/.well-known/oauth-protected-resource"):
            return try response(
                url: url,
                status: 200,
                json: #"{"resource":"https://mcp.gettimen.com/mcp","authorization_servers":["https://authorization.example"],"scopes_supported":["read","write","offline_access"]}"#
            )

        case ("GET", "authorization.example", "/.well-known/oauth-authorization-server"):
            return try response(
                url: url,
                status: 200,
                json: #"{"issuer":"https://authorization.example","authorization_endpoint":"https://authorization.example/authorize","token_endpoint":"https://authorization.example/token","registration_endpoint":"https://authorization.example/register","code_challenge_methods_supported":["S256"]}"#
            )

        case ("POST", "authorization.example", "/register"):
            let bodyData = try Self.bodyData(from: request)
            let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            let redirects = body?["redirect_uris"] as? [String] ?? []
            lock.withLock {
                registrationRequestCount += 1
                registrationRedirectURIs.append(contentsOf: redirects)
            }
            return try response(url: url, status: 201, json: #"{"client_id":"fresh-client"}"#)

        case ("POST", "authorization.example", "/token"):
            let form = Self.formFields(from: try Self.bodyData(from: request))
            let clientID = form["client_id"] ?? ""
            lock.withLock {
                tokenClientIDs.append(clientID)
                tokenCodes.append(form["code"] ?? "")
            }
            if clientID == "stale-client" {
                return try response(
                    url: url,
                    status: 401,
                    json: #"{"error":"invalid_client","error_description":"Unknown dynamic client"}"#
                )
            }
            guard clientID == "fresh-client" else {
                throw OAuthTestError.unexpectedRequest("unexpected token client: \(clientID)")
            }
            return try response(
                url: url,
                status: 200,
                json: #"{"access_token":"fresh-access-token","token_type":"Bearer","expires_in":3600,"refresh_token":"fresh-refresh-token","scope":"read write offline_access"}"#
            )

        default:
            throw OAuthTestError.unexpectedRequest("\(request.httpMethod ?? "GET") \(url.absoluteString)")
        }
    }

    private func response(url: URL, status: Int, json: String) throws -> (HTTPURLResponse, Data) {
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else { throw OAuthTestError.unexpectedRequest("could not create response") }
        return (response, Data(json.utf8))
    }

    private static func bodyData(from request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }

        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return body }
            if count < 0 { throw stream.streamError ?? OAuthTestError.unexpectedRequest("could not read request body") }
            body.append(buffer, count: count)
        }
    }

    private static func formFields(from data: Data) -> [String: String] {
        guard let body = String(data: data, encoding: .utf8) else { return [:] }
        return body.split(separator: "&").reduce(into: [:]) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            result[parts[0].removingPercentEncoding ?? parts[0]] =
                parts[1].removingPercentEncoding ?? parts[1]
        }
    }
}

private final class OAuthAuthenticateURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try OAuthAuthenticateRequestRecorder.shared.response(for: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class OAuthRequestRecorder: @unchecked Sendable {
    static let shared = OAuthRequestRecorder()

    private let lock = NSLock()
    private var requestCount = 0

    var registrationRequestCount: Int {
        lock.withLock { requestCount }
    }

    func reset() {
        lock.withLock {
            requestCount = 0
        }
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        lock.withLock {
            requestCount += 1
        }

        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 201,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (response, Data(#"{"client_id":"registered-client"}"#.utf8))
    }
}

private final class OAuthTestURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with _: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try OAuthRequestRecorder.shared.response(for: request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
