import Foundation
import Testing
@testable import AirAuth

private let testClientID = "123456-test.apps.googleusercontent.com"
private let testScheme = "com.googleusercontent.apps.123456-test"

private func configuration() throws -> OAuthConfiguration {
    try OAuthConfiguration(clientID: testClientID, redirectScheme: testScheme)
}

struct OAuthSecurityTests {
    @Test func rfc7636ChallengeVector() throws {
        let pkce = try PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(throws: OAuthError.invalidVerifier) { try PKCE(verifier: "short") }
        #expect(throws: OAuthError.invalidVerifier) { try PKCE(verifier: String(repeating: "+", count: 43)) }
    }

    @Test func generatedSecretsHaveIndependentSufficientEntropy() throws {
        let first = try OAuthAuthorizationRequest(configuration: configuration())
        let second = try OAuthAuthorizationRequest(configuration: configuration())
        #expect(first.pkce.verifier.count == 43)
        #expect(first.state.count == 43)
        #expect(first.state != first.pkce.verifier)
        #expect(first.state != second.state)
        #expect(first.pkce.verifier != second.pkce.verifier)
    }

    @Test func authorizationUsesOnlyApprovedScopesAndPKCE() throws {
        let request = try OAuthAuthorizationRequest(configuration: configuration())
        let components = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
        let fields = Dictionary(uniqueKeysWithValues: try #require(components.queryItems).map { ($0.name, $0.value ?? "") })
        #expect(fields["response_type"] == "code")
        #expect(fields["code_challenge_method"] == "S256")
        #expect(fields["code_challenge"] == request.pkce.challenge)
        #expect(fields["state"] == request.state)
        #expect(fields["redirect_uri"] == "\(testScheme):/oauth2redirect")
        #expect(fields["access_type"] == "offline")
        #expect(fields["prompt"] == "consent")
        let expected = ["activity_and_fitness", "health_metrics_and_measurements", "sleep", "profile"].map {
            "https://www.googleapis.com/auth/googlehealth.\($0).readonly"
        }
        #expect(Set((fields["scope"] ?? "").split(separator: " ").map(String.init)) == Set(expected))
        #expect(fields["client_secret"] == nil)
        #expect(fields["code_verifier"] == nil)
        #expect(fields["include_granted_scopes"] == nil)
    }

    @Test func rejectsMissingAndMismatchedClientConfiguration() throws {
        #expect(throws: OAuthError.invalidConfiguration) { try OAuthConfiguration(clientID: "", redirectScheme: "") }
        #expect(throws: OAuthError.invalidConfiguration) {
            try OAuthConfiguration(clientID: "$(FORM_GOOGLE_CLIENT_ID)", redirectScheme: testScheme)
        }
        #expect(throws: OAuthError.invalidConfiguration) {
            try OAuthConfiguration(clientID: testClientID, redirectScheme: "http")
        }
        #expect(throws: OAuthError.invalidConfiguration) {
            try OAuthConfiguration(clientID: testClientID, redirectScheme: "com.googleusercontent.apps.other")
        }
    }

    @Test func acceptsOnlyMatchingCallbackWithoutAmbiguity() throws {
        let request = try OAuthAuthorizationRequest(configuration: configuration())
        let valid = try #require(URL(string: "\(testScheme):/oauth2redirect?state=\(request.state)&code=authorized"))
        #expect(try request.authorizationCode(from: valid) == "authorized")
        let invalidCallbacks = [
            "wrong:/oauth2redirect?state=\(request.state)&code=x",
            "\(testScheme)://evil.example/oauth2redirect?state=\(request.state)&code=x",
            "\(testScheme):/different?state=\(request.state)&code=x",
            "\(testScheme):/oauth2redirect?state=wrong&code=x",
            "\(testScheme):/oauth2redirect?code=x",
            "\(testScheme):/oauth2redirect?state=\(request.state)&state=\(request.state)&code=x",
            "\(testScheme):/oauth2redirect?state=\(request.state)&code=x&code=y",
            "\(testScheme):/oauth2redirect?state=\(request.state)&code=x&error=access_denied",
            "\(testScheme):/oauth2redirect?state=\(request.state)&code=",
            "\(testScheme):/oauth2redirect?state=\(request.state)&code=x#fragment"
        ]
        for raw in invalidCallbacks {
            #expect(throws: (any Error).self) { try request.authorizationCode(from: #require(URL(string: raw))) }
        }
        let denied = try #require(URL(string: "\(testScheme):/oauth2redirect?state=\(request.state)&error=access_denied"))
        #expect(throws: OAuthError.permissionDenied) { try request.authorizationCode(from: denied) }
    }
}
