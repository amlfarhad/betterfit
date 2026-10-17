import Foundation

/// Safe, user-facing failures. OAuth URLs, codes, tokens and remote error bodies
/// are intentionally excluded from errors and diagnostics.
public enum OAuthError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidVerifier
    case randomGenerationFailed
    case invalidCallback
    case permissionDenied
    case authorizationFailed
    case signInInProgress
    case presentationUnavailable
    case unsupportedPlatform
    case notSignedIn
    case reauthorizationRequired
    case secureStorageUnavailable
    case networkUnavailable
    case serverUnavailable
    case invalidTokenResponse

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Google sign-in needs a dedicated iOS OAuth client ID and its registered reversed client URL scheme."
        case .invalidVerifier, .randomGenerationFailed:
            "A secure sign-in request could not be created. Please try again."
        case .invalidCallback:
            "The sign-in response could not be verified. Please try again."
        case .permissionDenied:
            "Google Health access was not granted. You can connect again when ready."
        case .authorizationFailed:
            "Google sign-in could not be completed. Please try again."
        case .signInInProgress:
            "A Google sign-in is already in progress."
        case .presentationUnavailable:
            "Open Form on screen to connect your Google account."
        case .unsupportedPlatform:
            "Google sign-in is available in the iPhone app. This preview supports demo data and file import."
        case .notSignedIn:
            "Connect your Google account to sync Google Health."
        case .reauthorizationRequired:
            "Google Health access has expired or been removed. Connect again to continue syncing."
        case .secureStorageUnavailable:
            "Secure account storage is unavailable. Unlock your device and try again."
        case .networkUnavailable:
            "Google could not be reached. Check your connection and try again."
        case .serverUnavailable:
            "Google sign-in is temporarily unavailable. Please try again later."
        case .invalidTokenResponse:
            "Google returned an incomplete sign-in response. Please connect again."
        }
    }
}

public struct OAuthConfiguration: Sendable, Equatable {
    public let clientID: String
    public let redirectScheme: String
    public var redirectURI: URL { URL(string: "\(redirectScheme):/oauth2redirect")! }

    public static let scopes = [
        "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
        "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
        "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
        "https://www.googleapis.com/auth/googlehealth.profile.readonly"
    ]

    public init(clientID: String, redirectScheme: String) throws {
        let suffix = ".apps.googleusercontent.com"
        guard clientID.hasSuffix(suffix) else { throw OAuthError.invalidConfiguration }
        let identifier = String(clientID.dropLast(suffix.count))
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard !identifier.isEmpty, identifier.unicodeScalars.allSatisfy(allowed.contains),
              identifier.first?.isNumber == true,
              redirectScheme == "com.googleusercontent.apps.\(identifier)" else {
            throw OAuthError.invalidConfiguration
        }
        self.clientID = clientID
        self.redirectScheme = redirectScheme
    }

    public static func load(bundle: Bundle = .main) throws -> OAuthConfiguration {
        guard let clientID = bundle.object(forInfoDictionaryKey: "FORM_GOOGLE_CLIENT_ID") as? String,
              let scheme = bundle.object(forInfoDictionaryKey: "FORM_GOOGLE_REDIRECT_SCHEME") as? String else {
            throw OAuthError.invalidConfiguration
        }
        let configuration = try OAuthConfiguration(clientID: clientID, redirectScheme: scheme)
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        guard types.contains(where: { ($0["CFBundleURLSchemes"] as? [String] ?? []).contains(scheme) }) else {
            throw OAuthError.invalidConfiguration
        }
        return configuration
    }
}
