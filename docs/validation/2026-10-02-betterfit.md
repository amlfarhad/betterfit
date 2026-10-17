# BetterFit build5 verification

## Preserved baseline
Source tag form-build4-stable (3437b77), plus exact signed build4 in ignored .private/recovery. Native migration tests prove the original raw cache bytes are unchanged. Phone metadata showed its original modification time retained after v2 refresh. Rollback procedure: ../betterfit-rollback.md.

## Automated checks
- Full release package:50engine tests,43UI tests,48sync tests,18auth tests, zero failures. Three opt-in benchmark/private-parity cases skipped in the normal run. Log: .build/betterfit-tests.log.
- Python audit/pipeline:44tests pass; .build/betterfit-python-tests.log.
- New suites cover calibrated/source-isolated baselines, zone thresholds, coverage and missing≠zero, sleep stages/timestamps/shortfall, precision stability, metric-specific quality gating, new-stream backfill/failure isolation, cache migration and clear.
- Saved dashboard tests cover early hydration while raw load is gated, raw replacement, imported/demo isolation, cancellation and account change, interrupted disconnect, invalid/corrupt input, limits and exact56calendar-day trimming while preserving visible scores.
- Independent reviews corrected the main-thread parsing cost (~1s to24–25ms for28synthetic insight evaluations), overlarge compact history, stale-day labels, missing-data copy and contributor consistency. No open review findings.

## Native builds and appearance
- Complete signed iPhone Release app+widget build succeeded with Xcode27; installed version5/com.amal.form on the paired iPhone15.
- Widgets: full iOSSimulator extension build, Swift6typecheck, standalone snapshot tests and synthetic SwiftUI layout render passed.
- Main dashboard inspected at393pt and375pt, plus tall full-page synthetic preview; dark graphitic depth, typography and three primary readings preserved. No clipped text at these standard sizes. Current new view-specific large Dynamic Type and real-phone FPS were not separately instrumented.
- Public previews contain synthetic readings only: ../design/previews/betterfit-today.png and betterfit-widgets.png.

## Actual phone evidence
Only app identity, file metadata and bounded status labels were read. No raw health readings, cache contents or tokens exported.

Successful final trace: saved_connected → dashboard_restored → widget_snapshot_saved → cache_restored → credentials_available → widget_snapshot_saved → refresh_applied; another foreground refresh also succeeded. Both old and new caches and the16KB compact file were present. The app's successful write diagnostic verifies its widget transport write returned without error. Device group-container listing did not expose that file, so do not claim widget readback or an actual Lock Screen render was observed.

App+extension profiles and signed entitlements both include group.com.amal.form under the existing free team. Profiles expire2026-10-10 at01:25:25/26UTC. User-controlled widget placement remains: hold Lock Screen→Customize→Add Widgets→BetterFit. Correct appearance/update behavior after placement still needs observation.

## Scope limits
New vitals and stages appear only when supplied by Google; no claim that every stream exists in the user's account. No BP estimate or arrhythmia diagnosis fabricated from HR summaries. Personal ranges are empirical comparisons, not medical normal ranges. Age equation unchanged and retains its movement-proxy limitation. No claim of guaranteed background real-time freshness; Google uploads and WidgetKit scheduling remain external constraints.

## Build7 follow-up: blank Sleep and partial-refresh warning

The user reported blank Sleep and a generic refresh warning. A diagnostic build emitted only public stream identifiers, error categories and score availability/reason labels; no measurement values or tokens were exported. The phone showed `invalid_sleep_stages` suppressing Sleep and Recovery, plus a temperature-stream validation failure. More precise error categories identified Google's optional temperature baseline as the latter failure.

Root causes and fixes:
- The new optional sleep-stage parser incorrectly rejected an otherwise valid whole-night summary. Cache ingestion now validates the core sleep summary independently. Bad stages remain flagged and omitted; valid duration, efficiency, regularity and Recovery inputs remain usable. The detail view explains the unavailable stage breakdown. Core invalid sleep summaries still reject, and unknown quality flags still fail closed.
- An optional Google temperature baseline, unused by this app, incorrectly blocked the independently valid nightly temperature. Only the nightly value is used and validated; BetterFit still computes its own prior-night baseline. Missing/nonfinite primary temperatures still reject.
- Refresh notices identify the affected streams and deduplicate failure windows.

Regression tests reproduced both failures before fixes, then passed. Full Release suite:50XCTest engine tests plus114SwiftTesting tests, zero failures (three opt-in private-parity/performance cases skipped). End-to-end sync tests cover committed valid summaries with invalid stages; UI tests verify precise refresh messages. On the phone, the intermediate fix changed states to `sleep_available` and `recovery_calibrating_insufficientBaseline`. Final build7 was installed and two actual phone refreshes reported `sync_no_failed_streams`, `sleep_available`, `recovery_calibrating_insufficientBaseline`, `widget_snapshot_saved` and `refresh_applied`. The generic warning is cleared because the failure list is empty. Existing Google credentials and raw cache remain intact.
