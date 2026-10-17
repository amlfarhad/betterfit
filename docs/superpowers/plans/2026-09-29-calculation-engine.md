# Calculation Engine Implementation Plan

> Use subagent-driven development for the isolated Swift package and scientific review; the primary agent owns Python ingestion and end-to-end integration. User has authorized implementation in this session. Keep the current workspace/branch because it contains the uncommitted, necessary audit tool.

**Goal:** Implement, document and validate local Sleep, Recovery, Strain and movement-based Biological Age calculations and the data freshness foundation.

**Architecture:** Native Swift library plus JSON CLI; Python private snapshot cache and canonical export; no frontend or deployed server.

**Tech Stack:** Swift 6 / Foundation / XCTest, Python 3 standard library / SQLite / unittest, existing Google Health OAuth.

## Tasks

- [x] Inspect actual schemas and research model/sync primary sources in independent bounded investigations.
- [x] Save explicit design and formulas in `docs/superpowers/specs/2026-09-29-calculation-engine-design.md`; verify compatible model inputs and scientific limitations.
- [x] Create `Package.swift`, `Sources/FitbitMetrics/`, `Sources/MetricsCLI/`, `tests/FitbitMetricsTests/`. Write golden/property/gate tests before implementation; run `swift test --disable-sandbox` with workspace-local caches, initially failing for missing behavior. Implement the exact schema and four functions from the design; JSON CLI reads an input file and writes JSON to stdout. No external dependencies or health files in tests.
- [x] Add Python tests and modules `fitbit_audit/store.py`, `fitbit_audit/normalize.py`, `fitbit_audit/sync.py`. Prove atomic replacement/rollback/deletion, duplicate handling, missing-vs-zero, correct local dates/DST, gap-aware HR integration, source conflicts, and stale/failed refresh behavior before implementation. Run `python3 -m unittest discover -s tests -v`.
- [x] Extend CLI with `sync` and `export` commands; keep credentials and snapshots private. Export schema v1 only from fully fetched raw snapshots; include capture-time freshness and explicit source/coverage issues.
- [x] Review model-selection evidence and license, implement any needed model-specific corrections, and compare Swift outputs to independently calculated golden values. Keep implementation validation separate from population/device validity.
- [x] Replay the user's private snapshot through normalization and Swift scores. Verify early-history states; reread current data with approved OAuth and check idempotence/corrections on a second import. Do not manufacture scores from insufficient data.
- [x] Obtain independent spec and code-quality reviews, fix findings, rerun relevant suites, save private validation report and public method/validation docs, update handoff.

## Reference commands

`python3 -m unittest discover -s tests -v`

`CLANG_MODULE_CACHE_PATH=.build/clang-cache swift test --disable-sandbox --cache-path .build/cache --scratch-path .build`

`python3 -m fitbit_audit export --timezone America/Los_Angeles`

`swift run --disable-sandbox metrics-cli .private/google-health/engine-input.json`

Completed on 2026-09-29: 44 Python tests, 34 Swift tests, 131 independent reference assertion groups, and private real-data replay pass. Independent review findings were fixed. See `docs/validation/2026-09-29-validation.md` and `docs/engine-api.md` for the verified host-specific Swift command; the simple scratch command above needs adjustment on this iCloud/Command Line Tools host.

The implementation and tests are the executable specification. No automatic deployment, scheduler, billing change, public sharing or raw health-data upload is included.
