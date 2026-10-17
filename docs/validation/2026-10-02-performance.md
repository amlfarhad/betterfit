# Form performance validation — 2026-10-02

The user reported slow downloads, pull-to-refresh and general scrolling/navigation lag after completing native Google sign-in. This pass changed the sync pipeline, repeated presentation work, chart gestures and the personal build configuration. Score formulas and the approved visual design were retained.

## Changes and evidence

- Pull-to-refresh bypasses the 60-second throttle without forcing three days of history on every pull. Regular 15-minute and weekly repairs remain.
- Completed attempt timestamps are separate from successful-sync timestamps. Failed windows retry only for the affected metric; healthy history is not downloaded repeatedly because another metric failed.
- Three metrics can download concurrently; each metric's windows/pages remain sequential. Concurrent refresh callers still share one operation.
- Timestamp validation reuses its compiled expression and calendar. Normalization reuses local-day boundaries. Cache replacement carries parsed event times through identity lookup and sorting instead of reparsing them.
- The sync actor supplies scores alongside their input. Publishing a snapshot no longer evaluates the same scores again on the UI actor.
- Date formatters are reused. Trends compute their points once per view evaluation and create history rows lazily.
- Charts use simultaneous horizontal dragging and tap selection instead of an exclusive zero-distance drag that interfered with vertical scrolling. Static charts have no active selection gesture. Repeated selection of the same date does not publish another change.
- Card shadows are applied to the background shape rather than all changing card content.
- Form Personal now uses Release for Run. The deployed app was launched without the Xcode debugger.

## Synthetic timings on the Mac

The fixture contains 90,000 synthetic heart-rate records, four seconds apart, with representative reconciled JSON fields. A warm replacement updates 1,800 records in that cache. Date presentation measures 20 updates of 28 days. These are single-run elapsed timings, not statistical distributions or measured iPhone frame rates. Other test work and host load can affect them.

| Operation | Before, Debug | After, Debug | After, Release |
| --- | ---: | ---: | ---: |
| Normalize 90,000 records | 1.287 s | 0.691 s | 0.282 s |
| Initial replacement | 1.162 s | 0.661 s | 0.364 s |
| Warm replacement | 1.011 s | 0.511 s | 0.243 s |
| Freshness scan | 0.384 s | 0.277 s | 0.070 s |
| Encode and save | 0.401 s | 0.408 s | 0.408 s |
| Repeated date presentation | 0.218 s | 0.074 s | 0.076 s |

The Debug-to-Debug comparison isolates the code changes more closely. Release includes compiler optimization as well. Persistence remains essentially unchanged; the full JSON cache is still encoded and atomically saved. The benchmark does not measure Google response latency, end-to-end phone sync duration, memory peaks, battery use or scrolling hitches.

Local ignored logs: `.build/sync-performance-before.log`, `.build/ui-performance-before.log`, `.build/performance-after-debug.log`, `.build/performance-release-tests.log`.

Reproduce synthetic benchmarks and the suite:

```sh
FORM_SYNC_BENCHMARK=1 \
DEVELOPER_DIR=/Users/amlfarhad/Downloads/Xcode.app/Contents/Developer \
swift test --disable-sandbox --scratch-path /private/tmp/form-performance-release -c release
```

## Correctness verification

The full Release run exited successfully: 34 engine XCTest tests, plus Swift Testing suite totals of 17 UI, 33 sync and 17 auth tests. The optional private Python-parity test was skipped; both synthetic benchmarks were enabled. Previously established private parity was not rerun against the phone cache.

New regressions cover manual refresh scope, the three-metric concurrency bound, failed-metric-only history retries, daily retry alignment after timezone changes, failure coverage across chunk boundaries, and matching precomputed scores to input. Tests first reproduced the scheduling/retry defects before their fixes. Existing replacement, source, persistence, authorization and account-transition tests remain passing.

The final cancellation refinement was run separately after the full suite. It waits for the fifth scheduled metric, guaranteeing an earlier metric result has already been staged, then cancels or clears. Both cases passed: cancellation preserves the prior cache byte-for-byte; clear removes it without a later task restoring it. Log: `.build/performance-cancellation-test.log`.

Python configuration and reconnect lifecycle tests: 12 passed. Log: `.build/performance-python-tests.log`. Read-only code review found no remaining P1/P2 findings after timezone and split-window retry fixes; its stronger cancellation-test recommendation was applied.

## Physical iPhone deployment

Signed Release build succeeded without warnings using Xcode 27, scheme Form Personal, `CURRENT_PROJECT_VERSION=2`. App identity, existing iOS OAuth configuration, device provisioning and signature passed validation before installation. Build: `/private/tmp/form-performance-device/Build/Products/Release-iphoneos/FormPersonal.app`. Log: `.build/form-performance-device.log`.

Installation and direct launch succeeded on the already-paired iPhone. Device metadata confirmed `com.amal.form`, version 1.0, build 2. The same bundle, team and OAuth client were used. Metadata-only inspection showed the existing cache and preferences still present, with the cache modified after launch. This is evidence of a save, not proof that every API endpoint succeeded or that the latest wearable measurements were uploaded.

Local ignored logs: `.build/performance-install.log`, `.build/performance-launch.log`, `.build/performance-installed-app.log`, `.build/performance-cache-metadata.log`.

The user previously confirmed Google consent and a live dashboard. Feedback on this update's scrolling/tab/refresh experience is pending. Two attempts to attach Time Profiler by process name and PID failed because xctrace could not resolve the device process; no physical-device trace or frame-rate result was obtained. Automatic approval review rejected exporting the private health cache; diagnostics continued with metadata and synthetic data, without copying account readings.

Next measurement if lag persists: identify the affected interaction on this Release build, obtain a working on-device Instruments trace, and measure frame hitches, memory and end-to-end refresh stages. Do not infer smooth scrolling or complete background reliability from these unit tests and Mac timings.
