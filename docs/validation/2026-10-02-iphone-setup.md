# Physical iPhone configuration — 2026-10-02

The user's screenshot confirms Form Personal launched on the physical iPhone. The subsequent Google sign-in alert was reproduced by inspecting the missing local iOS configuration and empty built client setting. The existing Desktop OAuth download was correctly rejected as unsuitable for native iOS sign-in.

## Completed

- Registered the public **Form iPhone** iOS OAuth client in the existing **Fitbit Air** project for the exact signed bundle `com.amal.form`.
- Downloaded Google's iOS plist and validated its bundle identity with the existing configuration helper. The ignored local xcconfig contains public identifiers only. Existing signing settings were preserved.
- Confirmed the existing account is an allowed Google test user. Sent the same client, callback, PKCE method and four read-only scopes used by the app to Google's authorization endpoint; it reached the account chooser. Closed that test before consent. This checks the entry point, not a complete OAuth exchange.
- Built **Form Personal** for `iphoneos` with the existing Personal Team. `xcodebuild` succeeded with zero warnings; `codesign --verify --deep --strict` passed. The provisioning profile includes the intended device and expires October 9, 2026 at 21:34:56 UTC. Built Info.plist contains the matching client and registered callback scheme.
- All 17 native authentication tests passed. All 12 Python configuration/installer tests passed. The installer lifecycle tests first failed against an inert implementation, then passed with the reconnect behavior implemented.
- Installer preflight passed against the real signed app. The real disconnected-device response produced the waiting state without an install attempt.

## Prepared installation

`scripts/install_on_reconnect.py` runs for a bounded period, selects the exact paired device, validates the app before installation, installs once, and launches Form. It does not grant Google access or alter phone trust/security settings. A launch failure can retry without reinstalling. It exits after successful launch, three failed installations, or timeout. The process requires the Mac to remain running; reconnecting and unlocking the iPhone is still necessary.

The active run's PID and status are stored in ignored `.build/form-reconnect-install.pid` and `.build/form-reconnect-install.log`. Its app is `/private/tmp/form-ready-device/Build/Products/Debug-iphoneos/FormPersonal.app`. Do not start duplicate watchers; check the existing run first.

## Still unverified

The configured replacement has not yet installed on the disconnected phone. Native Google consent, token exchange, live foreground sync, Keychain persistence and on-device background execution require the phone. Google's consent branding remains **Fitbit Personal Audit**, and the Cloud project remains in Testing; no publishing or permission expansion was performed. The app's local score calculations and visual design were unchanged in this setup fix.

Evidence: `.build/form-ready-device.log`, `.build/form-oauth-tests.log`, `.build/form-reconnect-install.log` (ignored local logs).
