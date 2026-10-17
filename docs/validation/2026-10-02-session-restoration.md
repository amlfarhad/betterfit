# Saved-session restoration — 2026-10-02

The user reported having to connect Google again after closing and reopening Form. A metadata-only settings check found the persisted mode was still `connected`. A diagnostic signed build then restored the saved cache, found Keychain credentials and refreshed on a fresh launch. No health readings or tokens were exported.

The UI nevertheless showed onboarding whenever `input == nil`, including the interval while the saved cache was opening. Its Connect button could start consent during restoration. Successful consent then intentionally cleared the old cache as part of the account transition. This combined a misleading signed-out appearance with a real route into unnecessary authorization and downloading.

## Fix

Startup state is observable, and onboarding is withheld until source restoration completes. A saved connected session with no displayed input has a separate opening/retry state. Connect is rejected while the selected source is restoring. The normal dashboard appears as soon as saved input is available, before a network refresh has to finish.

Missing or expired credentials and API 401/403 failures offer explicit reauthorization. Transient network errors keep retry behavior. When idle, an empty connected session exposes connection options so unavailable/corrupt caches cannot trap the user; existing import, reconnect and confirmed disconnect actions remain available. The token store, account-transition fence and scoring formulas are unchanged.

## Verification

- A delayed-restoration test failed against the old behavior, demonstrating both unwanted sign-in and cache clear. It passes after the Connect guard and presentation changes.
- New tests cover fresh-launch presentation, retained connected mode during network failure, explicit missing-credential recovery, 401/403 versus 500 handling, and an unreadable cache with explicit disconnect recovery.
- A newly created token provider reuses the earlier provider's stored refresh token after access-token expiry, using the refresh grant without another authorization-code exchange.
- Full Release suite passed: 34 engine XCTest tests; Swift Testing totals 22 UI, 33 sync and 18 auth. Two optional benchmarks and private Python parity were skipped. Logs: `.build/session-relaunch-red.log`, `.build/session-relaunch-green.log`, `.build/session-final-tests.log`.
- Independent review found a recovery-screen dead end; connection options and API authorization-error classification fixed it. Follow-up review found no remaining P1/P2 issues.
- Signed Release build 4 succeeded without warnings; app/OAuth identity, profile/device and signature validation passed. Installation and initial launch succeeded. The initial launch reported `saved_connected`, `cache_restored`, `credentials_available`, and `refresh_applied`.

Build/install logs: `.build/form-session-fix-build.log`, `.build/session-fix-install.log`, `.build/session-fix-first-launch.log`. Device event labels stay in ignored `.private/iphone-diagnostics/`. Diagnostics require the explicit `--session-diagnostics` launch argument; ordinary launches remove the diagnostic file and never record it. Labels contain no readings, tokens or account identity.

The additional terminate-and-relaunch verification succeeded on the physical iPhone: its new process again reported `saved_connected`, `cache_restored`, `credentials_available`, and `refresh_applied`. This verifies saved-session restoration through a real close/reopen cycle without a new consent flow. Log: `.build/session-fix-cold-relaunch.log`; status labels: ignored `.private/iphone-diagnostics/session-fixed-cold-relaunch.json`. Foreground restoration does not establish locked-device background refresh reliability.

Form was then closed and launched normally without diagnostic arguments. Installed-app metadata confirmed build4; a metadata-only file listing confirmed the diagnostic file was removed and the saved cache/preferences remained. Logs: `.build/session-fix-normal-launch.log`, `.build/session-fixed-installed-app.log`, `.build/session-fixed-normal-files.log`.
