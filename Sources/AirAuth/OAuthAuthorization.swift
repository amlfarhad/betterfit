import CryptoKit
import Foundation
import Security

struct PKCE: Sendable {
    let verifier: String
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URLString }

    init(verifier: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard (43...128).contains(verifier.utf8.count), verifier.unicodeScalars.allSatisfy(allowed.contains) else {
            throw OAuthError.invalidVerifier
        }
        self.verifier = verifier
    }

    init() throws { try self.init(verifier: secureRandomString()) }
}

private func secureRandomString() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw OAuthError.randomGenerationFailed
    }
    return Data(bytes).base64URLString
}

private extension Data {
    var base64URLString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct OAuthAuthorizationRequest: Sendable {
    let configuration: OAuthConfiguration
    let pkce: PKCE
    let state: String
    let url: URL

    init(configuration: OAuthConfiguration) throws {
        let pkce = try PKCE()
        let state = try secureRandomString()
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: OAuthConfiguration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            // Explicit connect/reauthorize asks for a refresh token. Routine
            // refresh never displays consent or extends the scope set.
            URLQueryItem(name: "prompt", value: "consent")
        ]
        self.configuration = configuration; self.pkce = pkce; self.state = state
        self.url = components.url!
    }

    func authorizationCode(from callback: URL) throws -> String {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.scheme == configuration.redirectScheme,
              components.host == nil, components.user == nil, components.password == nil,
              components.port == nil, components.percentEncodedPath == "/oauth2redirect",
              components.fragment == nil, let query = components.queryItems else {
            throw OAuthError.invalidCallback
        }
        var values: [String: String] = [:]
        for item in query where ["state", "code", "error"].contains(item.name) {
            guard values[item.name] == nil, let value = item.value, !value.isEmpty else {
                throw OAuthError.invalidCallback
            }
            values[item.name] = value
        }
        guard let returnedState = values["state"], equalState(returnedState, state) else {
            throw OAuthError.invalidCallback
        }
        if let error = values["error"] {
            guard values["code"] == nil else { throw OAuthError.invalidCallback }
            throw error == "access_denied" ? OAuthError.permissionDenied : OAuthError.authorizationFailed
        }
        guard let code = values["code"] else { throw OAuthError.invalidCallback }
        return code
    }

    private func equalState(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
