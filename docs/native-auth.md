# Native Google Health authentication

`AirAuth` uses an iPhone system authentication session, authorization code + PKCE (S256), fresh 256-bit state, and a dedicated iOS OAuth client. It requests exactly these existing read-only permissions:

- `https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly`
- `https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly`
- `https://www.googleapis.com/auth/googlehealth.sleep.readonly`
- `https://www.googleapis.com/auth/googlehealth.profile.readonly`

No identity/email permission, write scope, client secret, Desktop credential, or Desktop token file is used. The explicit Connect / Reauthorize action requests offline access with consent so Google can issue a refresh token. Routine refresh uses only the token endpoint.

## iPhone setup

Create an **iOS** OAuth client in the Google Cloud project that has Google Health API enabled. Configure its bundle identifier to match the signed iPhone app. Supply these build-expanded Info.plist values through the app's local configuration:

```xml
<key>FORM_GOOGLE_CLIENT_ID</key>
<string>YOUR_IOS_CLIENT_ID.apps.googleusercontent.com</string>
<key>FORM_GOOGLE_REDIRECT_SCHEME</key>
<string>com.googleusercontent.apps.YOUR_IOS_CLIENT_ID</string>
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array><string>com.googleusercontent.apps.YOUR_IOS_CLIENT_ID</string></array>
    </dict>
</array>
```

The placeholders above are illustrative and intentionally fail validation. Actual Google client identifiers have a numeric project prefix. Use the exact values generated for the iOS client. The redirect URI is the reversed scheme followed by `:/oauth2redirect` (a single slash, no host). `OAuthConfiguration.load()` checks the client ID format, matching reversed scheme, and its presence in `CFBundleURLTypes`. An iOS client and a Desktop client cannot be distinguished solely from the client ID's string format; the Google Cloud client type must be verified during setup. Do not reuse the Desktop client even if its text happens to pass these format checks.

The macOS visual preview deliberately returns `OAuthError.unsupportedPlatform` for sign-in. Import and synthetic demo remain available without credentials. No account is silently connected at first launch.

## Integration

```swift
import AirAuth

// Retain on the main actor for the life of the connection UI.
let configuration = try OAuthConfiguration.load()
let coordinator = GoogleSignInCoordinator(configuration: configuration)

// Only from the user's explicit connect action.
try await coordinator.signIn()

// Inject this operation into AirSync's request authorization.
let bearer = try await coordinator.tokenProvider.accessToken()

// Actor methods use await from the UI; Keychain failures are surfaced.
let connected = try await coordinator.tokenProvider.hasCredentials()
let grantedScopes = try await coordinator.tokenProvider.grantedScopes()
try await coordinator.disconnect()
```

Treat `CancellationError` as the user leaving sign-in or canceling work, not a failed account. `OAuthError` provides safe user-facing messages. Server response bodies, authorization URLs, codes, and tokens are never logged or attached to errors. A missing scope limits the corresponding data stream; the token record stores the scopes actually returned by Google and never assumes the requested scopes were all granted. The API layer must continue to handle permission errors if access changes later.

## Storage and lifecycle

The token actor owns all Keychain access. Tokens are app-private generic-password items keyed by client ID, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, synchronization disabled, and the data-protection Keychain enabled. They are excluded from app caches and widget snapshots. Locked-device background reads can fail; retry after unlock instead of weakening protection.

Valid access tokens are reused until the last 60 seconds of their lifetime. Concurrent callers share a refresh. Canceling one waiting caller returns promptly; other callers can continue, and cancellation of the last caller cancels the network work. A refresh response without a new refresh token preserves the existing refresh token. `invalid_grant` removes the unusable credentials and asks for reauthorization; transient network failures preserve the last credentials.

Reopening Form restores the selected source, loads its saved readings and resumes with the stored Keychain credentials. The UI distinguishes this startup phase from first-time onboarding: it shows an opening state until restoration resolves, and cannot start a new Connect flow while the existing source is loading. An empty but connected session offers retry and connection options; missing/expired credentials or an API 401/403 expose explicit reauthorization. A temporary network or cache error does not itself start Google consent or discard the session. Account transitions retain the existing cache-clear fence, so new credentials cannot use another account's old cache.

Disconnect cancels refresh waiters, invalidates pending authorization work, and removes local credentials. Generation and flight checks stop a late network result from saving them again. It makes no remote revocation request, because Google's project-level revocation can affect other clients. Cache removal is the app's separate responsibility. A Keychain deletion error is surfaced so the app does not claim secure storage was cleared when it was not.

The token endpoint uses an ephemeral URL session without cookies, URL caching, or credential storage; 30-second request and 60-second resource timeouts bound network waits. HTTP redirects are denied, and only the expected HTTPS token endpoint response is accepted. Callback validation requires the exact scheme/path, no host or fragment, matching state, and one unambiguous code or error.

## Verification and remaining device checks

The synthetic Swift Testing suite covers the RFC 7636 challenge vector, entropy shape, scope isolation, callback mismatch/duplicate/denial boundaries, expiry margins, refresh concurrency and cancellation, disconnect during refresh and code exchange, refresh-token preservation, invalid-grant handling, malformed responses, and partial consent. Tests inject an in-memory store and transport: they do not access a real Google account or write account tokens to the developer's Keychain.

The Foundation, CryptoKit, Security, token actor and macOS fallback compile, and the iOS-only `ASWebAuthenticationSession` path compiles with Xcode 27 against both simulator and physical-iPhone SDKs. On 2026-10-02, the configured signed iPhone build completed consent and live sync. A subsequent fresh launch reported saved connected mode, restored cache, available Keychain credentials and a completed refresh without requiring a new authorization flow. Background behavior remains best effort and is not established by that foreground check. See [session-restoration validation](validation/2026-10-02-session-restoration.md).

For developer diagnosis only, launching with `--session-diagnostics` writes at most 12 event labels into the private `session-diagnostics.json`. Labels describe restoration, cache availability, credential availability and refresh outcome; no tokens, OAuth URLs, identity fields or health values are written. Previews never write this file. Normal launches do not record it and remove any file from the earlier diagnostic run.

Official references checked on 2026-09-29:

- [Google OAuth for iOS and Desktop apps](https://developers.google.com/identity/protocols/oauth2/native-app)
- [Google Health setup and consent](https://developers.google.com/health/setup)
- [Google Health permission scopes](https://developers.google.com/health/scopes)
