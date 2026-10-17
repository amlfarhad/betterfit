# Form Native App Implementation Plan

> Use subagent-driven-development for independent native data/auth units; primary owns UI/project/integration and reviews each unit. User authorized implementation and approved the dark visual direction. Reuse current checkout containing all required uncommitted engine work. Do not create a checkout that loses it.

**Goal:** A working native iPhone app with a premium visual system, real account sync integration, tested score presentation and widgets.

**Architecture:** Local Swift package products FitbitMetrics + AirSync + AirAuth + AirUI; iOS app/WidgetKit targets and a macOS SwiftUI QA host. No paid backend.

**Tech Stack:** Swift 6, SwiftUI, Foundation, CryptoKit, Security, AuthenticationServices, WidgetKit, BackgroundTasks.

- [x] Write AirSync synthetic regression tests, then implement read-only paginated Google Health client, bounded refresh, atomic cache and normalization into InputBundle. Sources/AirSync and tests/AirSyncTests. Compare native and Python normalization on private fixtures; no secret output.
- [x] Write PKCE/state/redirect/token tests; implement Google iOS configuration validation, system authentication session and Keychain storage in Sources/AirAuth and tests/AirAuthTests. Unconfigured build reports setup needed; no embedded Desktop credentials.
- [x] Add package products and native design system, dashboard, metric sheets, trends, biological-age collection, connection/import/onboarding and scene-aware model under Sources/AirUI. Real engine values drive all charts/states. Create explicit synthetic DemoFactory; never load it as a live fallback.
- [x] Create AirPreview native macOS host and reproducible renderer for real SwiftUI screenshots. Inspect at 393px and 375px; adjust composition, typography and contrast using screenshots, not only assertions. Check navigation and controls using native UI automation.
- [x] Create iOS/Form @main lifecycle, background registration, Info.plist/build configuration, widget snapshot bridge, iOS/FormWidgets and checked-in Xcode project. Keep App Group/signing configurable. Validate project/plists on this host and build iOS if a full SDK becomes available.
- [x] Review spec compliance and code quality, fix findings, run targeted suites and native compilation. Update README, installation instructions, validation record and HANDOFF with verified outcomes and exact remaining setup.

Reference verification: existing host Swift Testing command from docs/engine-api.md, scratch /private/tmp/form-native-build; python3 -m unittest discover -s tests -v. Native build logs are capped or saved to .build and read in focused ranges. Private snapshots/screenshots remain under .private and are never packaged or committed. No tests that simply mirror low-impact view decoration.

Native implementation, independent reviews, regression suites and simulator/device-SDK builds completed 2026-09-29. Live OAuth configuration, physical signing and on-device checks remain as recorded in docs/validation/2026-09-29-native-app.md.
