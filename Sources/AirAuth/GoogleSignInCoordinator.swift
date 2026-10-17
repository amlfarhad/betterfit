import Foundation
#if os(iOS)
import AuthenticationServices
import UIKit
#endif

/// Presents Google's consent in the system authentication browser on iPhone.
/// The app owns this coordinator for at least the duration of `signIn()`.
@MainActor
public final class GoogleSignInCoordinator: NSObject {
    public let tokenProvider: GoogleHealthTokenProvider
    private let configuration: OAuthConfiguration
    private var activeSignInID: UUID?
    #if os(iOS)
    private var browserSession: ASWebAuthenticationSession?
    private var browserContinuation: CheckedContinuation<URL, any Error>?
    private var presentationWindow: UIWindow?
    #endif

    public init(configuration: OAuthConfiguration, tokenProvider: GoogleHealthTokenProvider? = nil) {
        self.configuration = configuration
        self.tokenProvider = tokenProvider ?? GoogleHealthTokenProvider(configuration: configuration)
        super.init()
    }

    public func signIn() async throws {
        #if os(iOS)
        guard activeSignInID == nil else { throw OAuthError.signInInProgress }
        try Task.checkCancellation()
        let id = UUID()
        activeSignInID = id
        defer { if activeSignInID == id { activeSignInID = nil } }
        let request = try OAuthAuthorizationRequest(configuration: configuration)
        let callback = try await authenticate(request, id: id)
        try Task.checkCancellation()
        guard activeSignInID == id else { throw CancellationError() }
        let code = try request.authorizationCode(from: callback)
        try await tokenProvider.exchangeAuthorizationCode(code, verifier: request.pkce.verifier)
        #else
        throw OAuthError.unsupportedPlatform
        #endif
    }

    public func disconnect() async throws {
        #if os(iOS)
        if let id = activeSignInID {
            browserSession?.cancel()
            finishBrowser(id: id, result: .failure(CancellationError()))
        }
        #endif
        activeSignInID = nil
        try await tokenProvider.disconnect()
    }

    #if os(iOS)
    private func authenticate(_ request: OAuthAuthorizationRequest, id: UUID) async throws -> URL {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.filter({ $0.activationState == .foregroundActive })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { throw OAuthError.presentationUnavailable }
        presentationWindow = window
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                browserContinuation = continuation
                let session = ASWebAuthenticationSession(url: request.url, callbackURLScheme: configuration.redirectScheme) { [weak self] callback, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                            self.finishBrowser(id: id, result: .failure(CancellationError()))
                        } else if error != nil {
                            self.finishBrowser(id: id, result: .failure(OAuthError.authorizationFailed))
                        } else if let callback {
                            self.finishBrowser(id: id, result: .success(callback))
                        } else {
                            self.finishBrowser(id: id, result: .failure(OAuthError.invalidCallback))
                        }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                browserSession = session
                if !session.start() { finishBrowser(id: id, result: .failure(OAuthError.presentationUnavailable)) }
            }
        } onCancel: {
            Task { @MainActor in
                guard self.activeSignInID == id else { return }
                self.browserSession?.cancel()
                self.finishBrowser(id: id, result: .failure(CancellationError()))
            }
        }
    }

    private func finishBrowser(id: UUID, result: Result<URL, any Error>) {
        guard activeSignInID == id, let continuation = browserContinuation else { return }
        browserContinuation = nil
        browserSession = nil
        presentationWindow = nil
        continuation.resume(with: result)
    }
    #endif
}

#if os(iOS)
extension GoogleSignInCoordinator: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // authenticate() has already verified and retained the foreground window.
        presentationWindow ?? ASPresentationAnchor()
    }
}
#endif
