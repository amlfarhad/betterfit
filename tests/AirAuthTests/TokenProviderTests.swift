import Foundation
import Testing
@testable import AirAuth

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
private func testConfiguration() throws -> OAuthConfiguration {
    try OAuthConfiguration(clientID: "123456-test.apps.googleusercontent.com", redirectScheme: "com.googleusercontent.apps.123456-test")
}

private final class MemoryTokenStore: OAuthTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OAuthTokens?
    init(_ tokens: OAuthTokens? = nil) { self.tokens = tokens }
    func load() throws -> OAuthTokens? { lock.withLock { tokens } }
    func save(_ value: OAuthTokens) throws { lock.withLock { tokens = value } }
    func remove() throws { lock.withLock { tokens = nil } }
}

private actor TestTransport: OAuthTransport {
    private(set) var requests: [URLRequest] = []
    let body: String
    let status: Int
    let delayed: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    init(body: String = #"{"access_token":"new-access","expires_in":3600,"token_type":"Bearer"}"#,
         status: Int = 200, delayed: Bool = false) {
        self.body = body; self.status = status; self.delayed = delayed
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if delayed { await withCheckedContinuation { continuation = $0 } }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func release() { continuation?.resume(); continuation = nil }
    func waitUntilCalled() async {
        while requests.isEmpty { await Task.yield() }
    }
}

struct TokenProviderTests {
    private func expiredTokens() -> OAuthTokens {
        OAuthTokens(accessToken: "old-access", refreshToken: "refresh+a&b", expiresAt: fixedNow.addingTimeInterval(-1), grantedScopes: [])
    }

    @Test func savedAuthorizationSurvivesNewProviderAndRefreshesWithoutConsent() async throws {
        let store = MemoryTokenStore()
        let signInTransport = TestTransport(body: #"{"access_token":"first-access","refresh_token":"saved-refresh","expires_in":3600,"token_type":"Bearer"}"#)
        let first = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: store,
            transport: signInTransport, now: { fixedNow })
        try await first.exchangeAuthorizationCode("synthetic-code", verifier: String(repeating: "a", count: 43))
        let refreshTransport = TestTransport()
        let reopened = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: store,
            transport: refreshTransport, now: { fixedNow.addingTimeInterval(7200) })
        #expect(try await reopened.hasCredentials())
        #expect(try await reopened.accessToken() == "new-access")
        let requests = await refreshTransport.requests
        #expect(requests.count == 1)
        let data = try #require(requests.first?.httpBody)
        let body = try #require(String(data: data, encoding: .utf8))
        #expect(body.contains("grant_type=refresh_token"))
        #expect(!body.contains("authorization_code"))
        #expect(try store.load()?.refreshToken == "saved-refresh")
    }

    @Test func validCachedAccessTokenDoesNotContactNetwork() async throws {
        let tokens = OAuthTokens(accessToken: "valid", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(3600), grantedScopes: [])
        let transport = TestTransport()
        let provider = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: MemoryTokenStore(tokens), transport: transport, now: { fixedNow })
        #expect(try await provider.accessToken() == "valid")
        #expect(await transport.requests.isEmpty)
    }

    @Test func refreshPreservesRefreshTokenAndEncodesWithoutSecret() async throws {
        let store = MemoryTokenStore(expiredTokens())
        let transport = TestTransport()
        let provider = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: store, transport: transport, now: { fixedNow })
        #expect(try await provider.accessToken() == "new-access")
        let request = try #require(await transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let bodyData = try #require(request.httpBody)
        let body = try #require(String(data: bodyData, encoding: .utf8))
        #expect(body.contains("refresh_token=refresh%2Ba%26b"))
        #expect(!body.contains("client_secret"))
        #expect(try store.load()?.refreshToken == "refresh+a&b")
        #expect(try store.load()?.expiresAt == fixedNow.addingTimeInterval(3600))
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let transport = TestTransport(delayed: true)
        let provider = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: MemoryTokenStore(expiredTokens()), transport: transport, now: { fixedNow })
        let tasks = (0..<12).map { _ in Task { try await provider.accessToken() } }
        await transport.waitUntilCalled()
        await transport.release()
        for task in tasks { #expect(try await task.value == "new-access") }
        #expect(await transport.requests.count == 1)
    }

    @Test func disconnectPreventsLateRefreshFromRestoringTokens() async throws {
        let store = MemoryTokenStore(expiredTokens())
        let transport = TestTransport(delayed: true)
        let provider = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: store, transport: transport, now: { fixedNow })
        let task = Task { try await provider.accessToken() }
        await transport.waitUntilCalled()
        try await provider.disconnect()
        await transport.release()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(try store.load() == nil)
        #expect(try await !provider.hasCredentials())
    }

    @Test func cancellationReturnsWithoutWaitingForTransport() async throws {
        let transport = TestTransport(delayed: true)
        let provider = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: MemoryTokenStore(expiredTokens()), transport: transport, now: { fixedNow })
        let task = Task { try await provider.accessToken() }
        await transport.waitUntilCalled()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await transport.release()
    }

    @Test func invalidGrantClearsExpiredCredentials() async throws {
        let store = MemoryTokenStore(expiredTokens())
        let transport = TestTransport(body: #"{"error":"invalid_grant","error_description":"must never surface server data"}"#, status: 400)
        let provider = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: store, transport: transport, now: { fixedNow })
        await #expect(throws: OAuthError.reauthorizationRequired) { try await provider.accessToken() }
        #expect(try store.load() == nil)
    }

    @Test func transientFailurePreservesCredentials() async throws {
        let store = MemoryTokenStore(expiredTokens())
        let provider = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: store, transport: TestTransport(body: "unavailable", status: 503), now: { fixedNow })
        await #expect(throws: OAuthError.serverUnavailable) { try await provider.accessToken() }
        #expect(try store.load()?.refreshToken == "refresh+a&b")
    }

    @Test func authorizationExchangeStoresOnlyGrantedScopes() async throws {
        let store = MemoryTokenStore()
        let transport = TestTransport(body: #"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/googlehealth.sleep.readonly"}"#)
        let provider = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: store, transport: transport, now: { fixedNow })
        try await provider.exchangeAuthorizationCode("code", verifier: String(repeating: "a", count: 43))
        #expect(try store.load()?.grantedScopes == ["https://www.googleapis.com/auth/googlehealth.sleep.readonly"])
        let bodyData = try #require(await transport.requests.first?.httpBody)
        let body = try #require(String(data: bodyData, encoding: .utf8))
        #expect(body.contains("code_verifier="))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(!body.contains("client_secret"))
    }

    @Test func disconnectAlsoRejectsLateAuthorizationExchange() async throws {
        let store = MemoryTokenStore()
        let transport = TestTransport(delayed: true)
        let provider = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: store, transport: transport, now: { fixedNow })
        let signIn = Task { try await provider.exchangeAuthorizationCode("code", verifier: String(repeating: "a", count: 43)) }
        await transport.waitUntilCalled()
        try await provider.disconnect()
        await transport.release()
        await #expect(throws: CancellationError.self) { try await signIn.value }
        #expect(try store.load() == nil)
    }

    @Test(arguments: [59, 60, 61])
    func expiryMarginRefreshesBeforeAccessTokenExpires(seconds: Int) async throws {
        let store = MemoryTokenStore(OAuthTokens(accessToken: "cached", refreshToken: "refresh", expiresAt: fixedNow.addingTimeInterval(Double(seconds)), grantedScopes: []))
        let transport = TestTransport()
        let provider = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: store, transport: transport, now: { fixedNow })
        #expect(try await provider.accessToken() == (seconds > 60 ? "cached" : "new-access"))
        #expect(await transport.requests.count == (seconds > 60 ? 0 : 1))
    }

    @Test(arguments: [
        #"{"access_token":"access","expires_in":0,"token_type":"Bearer"}"#,
        #"{"access_token":"access","expires_in":-1,"token_type":"Bearer"}"#,
        #"{"access_token":"","expires_in":3600,"token_type":"Bearer"}"#,
        #"{"access_token":"access","expires_in":3600,"token_type":"Unknown"}"#,
        #"{"access_token":"access","token_type":"Bearer"}"#
    ])
    func malformedTokenResponsesNeverReplaceStoredTokens(body: String) async throws {
        let store = MemoryTokenStore(expiredTokens())
        let provider = GoogleHealthTokenProvider(configuration: try testConfiguration(), store: store, transport: TestTransport(body: body), now: { fixedNow })
        await #expect(throws: OAuthError.invalidTokenResponse) { try await provider.accessToken() }
        #expect(try store.load() == expiredTokens())
    }

    #if !os(iOS)
    @Test @MainActor func previewReportsUnsupportedSignIn() async throws {
        let coordinator = GoogleSignInCoordinator(configuration: try testConfiguration())
        await #expect(throws: OAuthError.unsupportedPlatform) { try await coordinator.signIn() }
    }
    #endif
}
