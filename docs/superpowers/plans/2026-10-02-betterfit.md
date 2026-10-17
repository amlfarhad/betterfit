# BetterFit Implementation Plan

> Use subagent-driven-development for isolated implementation tasks and final independent review. Shared checkout, narrow file ownership; no broad regeneration or account-data export.

**Goal:** Make BetterFit understandable, richer and recoverable without sacrificing existing smoothness or account safety.

**Architecture:** Native SwiftUI; deterministic FitbitMetrics interpretation layer; AirSync adds optional daily vitals; versioned raw cache preserves rollback; WidgetKit uses last validated shared snapshot.

**Tech Stack:** Swift6, SwiftUI, WidgetKit, Xcode27, Python project tooling.

- [x] Preserve source tag/commit and signed build4 before editing.
- [ ] Data task: verify official daily vitals/stage schemas, extend optional models/validation, implement sync/cache migration and synthetic tests. Files Sources/AirSync/*, Sources/FitbitMetrics/Models.swift and Validation.swift, tests/AirSyncTests/*.
- [ ] Interpretation task: add pure BetterFitInsights.swift and tests for intensity minutes, prior complete-day comparisons, sleep deficit/efficiency/regularity and robust personal vital ranges. No diagnosis, no false precision, no opaque replacement score. Audit existing strain mapping with synthetic examples; document.
- [ ] Widget task: circular Recovery/Activity/Sleep + rectangular summary, stale/calibrating state and deep links; test snapshot acceptance. Files iOS/FormWidgets/*, iOS/Tests/WidgetSnapshotTests.swift. Investigate legitimate free-team sharing/signing; report before changing capabilities.
- [ ] Parent: BetterFit identity, original non-letter icon, explanatory dashboard/details/trends/vitals, returning-user skeleton/presentation cache, conditional widgets guidance. Files Sources/AirUI/*, iOS app config, icon tool; coordinate widget snapshot contract.
- [ ] Review data safety/spec compliance and UI state/failure recovery. Run relevant Swift tests, widget checks, signed build and simulator render checks.
- [ ] Verify new phone install/cold reopen, metadata-only data availability and widget provisioning; retain old build/cache; document restoration command and limits. Commit final verified state separately from baseline.
