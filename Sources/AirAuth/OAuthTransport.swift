import Foundation

public protocol OAuthTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionOAuthTransport: OAuthTransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        self.session = URLSession(configuration: configuration, delegate: RejectTokenRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw OAuthError.invalidTokenResponse }
            return (data, response)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as OAuthError { throw error }
        catch { throw OAuthError.networkUnavailable }
    }
}

private final class RejectTokenRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward a credential-bearing POST through an HTTP redirect.
        completionHandler(nil)
    }
}

struct OAuthTokenEndpoint: Sendable {
    let configuration: OAuthConfiguration
    let transport: any OAuthTransport
    let now: @Sendable () -> Date
    private let url = URL(string: "https://oauth2.googleapis.com/token")!

    func exchange(code: String, verifier: String) async throws -> OAuthTokens {
        _ = try PKCE(verifier: verifier)
        guard !code.isEmpty else { throw OAuthError.invalidCallback }
        return try await request(fields: [
            "grant_type": "authorization_code", "client_id": configuration.clientID,
            "code": code, "code_verifier": verifier,
            "redirect_uri": configuration.redirectURI.absoluteString
        ], previous: nil)
    }

    func refresh(_ previous: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = previous.refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.reauthorizationRequired
        }
        return try await request(fields: [
            "grant_type": "refresh_token", "client_id": configuration.clientID,
            "refresh_token": refreshToken
        ], previous: previous)
    }

    private func request(fields: [String: String], previous: OAuthTokens?) async throws -> OAuthTokens {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        guard response.url == url, data.count <= 65_536 else { throw OAuthError.invalidTokenResponse }
        if response.statusCode == 429 || response.statusCode >= 500 { throw OAuthError.serverUnavailable }
        guard (200...299).contains(response.statusCode) else {
            let failure = try? JSONDecoder().decode(TokenFailure.self, from: data)
            if failure?.error == "invalid_grant" { throw OAuthError.reauthorizationRequired }
            if failure?.error == "access_denied" { throw OAuthError.permissionDenied }
            throw OAuthError.authorizationFailed
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !token.access_token.isEmpty, token.token_type.caseInsensitiveCompare("Bearer") == .orderedSame,
              token.expires_in.isFinite, token.expires_in > 0 else {
            throw OAuthError.invalidTokenResponse
        }
        let expiresAt = now().addingTimeInterval(token.expires_in)
        guard expiresAt.timeIntervalSince1970.isFinite else { throw OAuthError.invalidTokenResponse }
        return OAuthTokens(accessToken: token.access_token,
                           refreshToken: token.refresh_token.flatMap { $0.isEmpty ? nil : $0 } ?? previous?.refreshToken,
                           expiresAt: expiresAt,
                           grantedScopes: token.scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.grantedScopes ?? [])
    }

    private struct TokenFailure: Decodable { let error: String }
    private struct TokenResponse: Decodable {
        let access_token: String
        let token_type: String
        let expires_in: TimeInterval
        let refresh_token: String?
        let scope: String?
    }
}
