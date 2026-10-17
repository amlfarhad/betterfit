# Form native app validation

Verified 2026-09-29 with Xcode 27, Swift 6, macOS 27.0.1 and iOS 27 Simulator. Software validation is not clinical validation.

## Delivered

Native Today dashboard, Recovery/Strain/Sleep and raw-signal details, 7/28-day trends, Biological Age with collection/methodology, onboarding, snapshot import, explicit sample mode, connection and sleep-target controls. Graphite/ivory design, distinct metric colors, custom type, illuminated surfaces, gauges, charts, capsule navigation, transitions and an original app icon. No generic List/Form screens.

Native read-only API adapter/cache, PKCE/system authentication/Keychain, foreground/manual refresh, best-effort background coordinator and small/medium WidgetKit layouts. Form Personal omits widgets and App Groups for free Personal Team signing. Canceled consent preserves offline cache; failed account transitions leave a durable disconnected state; startup and refresh wait for restoration. Source mode and sleep targets persist.

## Automated evidence

| Suite | Result |
| --- | --- |
| FitbitMetrics | 34 tests passed using full XCTest |
| AirSync | 26 tests passed, including private Python input/scoring parity |
| AirAuth | 17 tests passed |
| AirUI state | 16 tests passed |
| Python pipeline | 44 tests passed |
| iOS configuration helper | 6 tests passed |

Total: 93 logical Swift tests and 50 Python tests. Parameterized cases add coverage. Private parity was enabled with a mode-0600 temporary fixture; it compared native normalization and scores with the audited Python adapter without logging measurements. The earlier independent engine reference passed 131 assertion groups.

The widget-link regression first failed because a historical date remained selected, then passed after the link selected the latest snapshot. Account transition, canceled consent, persistence failure, preview isolation and concurrent startup/refresh have regression coverage.

## Native build and visual evidence

- Follow-up signed simulator build passed after setting Debug `COPY_PHASE_STRIP=NO`. The widget copy command no longer attempted symbol stripping; both app and widget signing completed, with zero `not stripping binary because it is signed` warnings. Release settings remain unchanged. Evidence: `.build/widget-warning-build.log`.
- Form app and embedded widget: iOS Simulator build passed. Form Personal simulator build passed; built Info.plist has an empty App Group, no PlugIns directory, and compiled icon assets.
- Form app and widget: unsigned physical-iPhone SDK build passed. Compilation does not verify provisioning or physical installation.
- Installed and directly launched Form on iPhone 18 Pro / iOS 27 Simulator; welcome screen rendered. Xcode's first Run had an architecture mismatch, fixed by Debug ONLY_ACTIVE_ARCH. A later GUI debugger attachment stalled; direct simctl launch succeeded.
- Shared native macOS QA host: opened Recovery detail, selected another date and observed score/contributors change; switched week/month and Sleep trend filter; opened Age and expanded the research disclosure; changed sleep target from 8h to 8h15m.
- Visually reviewed shared SwiftUI renders at 393 and 375 logical pixels. Fixed static-render ScrollView behavior, a decorative placeholder, demo labels, missing-versus-calibrating language, historical-date titles and measurement-time labels.
- Private real-input age render showed three-of-seven qualifying days. Real-input images remain mode0600 in `.private/google-health/`, outside source and app resources.

Public images in `docs/design/previews/` contain synthetic data or onboarding only. `today.png`, `age.png`, `trends-compact.png` and `welcome.png` use the actual shared SwiftUI views in a macOS QA frame; its status bar is synthetic. `ios-welcome.png` is an actual iPhone simulator capture. Do not label shared-view renders as simulator screenshots.

## Reproduce

This host needs `DEVELOPER_DIR=/Users/amlfarhad/Downloads/Xcode.app/Contents/Developer`. Temporary scratch paths avoid synced-workspace metadata issues.

```sh
swift test --disable-sandbox --scratch-path /private/tmp/form-final-tests
python3 -m unittest discover -s tests -v
python3 -m unittest discover -s iOS/Tests -p 'test_*.py' -v
xcodebuild -project iOS/Form.xcodeproj -scheme Form \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/form-ios-build CODE_SIGNING_ALLOWED=NO build
xcodebuild -project iOS/Form.xcodeproj -scheme Form \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/form-device-build CODE_SIGNING_ALLOWED=NO build
```

Set `AIRSYNC_PARITY_FIXTURE` as described in `docs/native-sync.md` to enable local private parity. Otherwise that one test skips. Logs are under ignored `.build/`.

## Remaining setup and device checks

Live Google iOS authorization is not configured or exercised. Available Desktop downloads are not phone configurations. Create an iOS client matching the final bundle ID, run `scripts/configure_ios.py`, and complete consent on the phone. No credential or personal snapshot is bundled.

Physical signing/Developer Mode, signed-device Keychain, the iOS document picker, installed widgets, locked-device/background delivery, battery use and large-cache performance remain unverified. A successful Desktop account pipeline does not prove the new iOS OAuth flow works for this account.

Google Health must upload/process readings before Form can retrieve them. Foreground polling and iOS background opportunities cannot guarantee identical freshness. Keychain WhenUnlockedThisDeviceOnly can defer locked-device work. Widgets show saved snapshots; they never independently call Google.

Free Personal Team profiles currently expire after seven days; periodic Xcode reinstall is required. Widgets need an App Group-capable team. No paid membership/service/relay was purchased. See `docs/ios-installation.md`.
