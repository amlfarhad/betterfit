import Foundation

/// Owns all token state and Keychain access. Refresh callers share one flight;
/// cancelling an individual caller does not cancel other callers' work.
public actor GoogleHealthTokenProvider {
    private let store: any OAuthTokenStore
    private let endpoint: OAuthTokenEndpoint
    private let now: @Sendable () -> Date
    private var tokens: OAuthTokens?
    private var hasLoaded = false
    private var generation: UInt64 = 0
    private var refreshID: UUID?
    private var refreshTask: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<String, any Error>] = [:]

    public init(configuration: OAuthConfiguration,
                store: (any OAuthTokenStore)? = nil,
                transport: any OAuthTransport = URLSessionOAuthTransport(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store ?? KeychainTokenStore(clientID: configuration.clientID)
        self.endpoint = OAuthTokenEndpoint(configuration: configuration, transport: transport, now: now)
        self.now = now
    }

    public func hasCredentials() throws -> Bool {
        guard let tokens = try load() else { return false }
        return tokens.refreshToken?.isEmpty == false || tokens.expiresAt > now()
    }

    public func grantedScopes() throws -> [String] { try load()?.grantedScopes ?? [] }

    public func accessToken() async throws -> String {
        try Task.checkCancellation()
        guard let tokens = try load() else { throw OAuthError.notSignedIn }
        if tokens.expiresAt.timeIntervalSince(now()) > 60 { return tokens.accessToken }
        guard tokens.refreshToken?.isEmpty == false else { throw OAuthError.reauthorizationRequired }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waiters[waiterID] = continuation
                if refreshTask == nil { startRefresh(tokens) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    /// Called only after the coordinator verifies the active callback and state.
    public func exchangeAuthorizationCode(_ code: String, verifier: String) async throws {
        generation &+= 1
        let expectedGeneration = generation
        cancelRefresh()
        let result = try await endpoint.exchange(code: code, verifier: verifier)
        try Task.checkCancellation()
        guard expectedGeneration == generation else { throw CancellationError() }
        try store.save(result)
        tokens = result
        hasLoaded = true
    }

    /// Local disconnect deliberately does not revoke the Google project grant.
    public func disconnect() throws {
        generation &+= 1
        cancelRefresh()
        tokens = nil
        hasLoaded = true
        try store.remove()
    }

    private func load() throws -> OAuthTokens? {
        if !hasLoaded { tokens = try store.load(); hasLoaded = true }
        return tokens
    }

    private func startRefresh(_ previous: OAuthTokens) {
        let id = UUID()
        refreshID = id
        refreshTask = Task {
            do {
                let result = try await endpoint.refresh(previous)
                try Task.checkCancellation()
                completeRefresh(id: id, result: .success(result))
            } catch {
                completeRefresh(id: id, result: .failure(error))
            }
        }
    }

    private func completeRefresh(id: UUID, result: Result<OAuthTokens, any Error>) {
        guard refreshID == id else { return }
        let outcome: Result<String, any Error>
        do {
            switch result {
            case .success(let value):
                try store.save(value)
                tokens = value
                hasLoaded = true
                outcome = .success(value.accessToken)
            case .failure(let error):
                if error as? OAuthError == .reauthorizationRequired {
                    tokens = nil; hasLoaded = true
                    try store.remove()
                }
                outcome = .failure(error)
            }
        } catch { outcome = .failure(error) }
        let pending = waiters.values
        waiters.removeAll()
        refreshID = nil; refreshTask = nil
        for waiter in pending { waiter.resume(with: outcome) }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if waiters.isEmpty { cancelRefresh() }
    }

    private func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil; refreshID = nil
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: CancellationError()) }
    }
}
