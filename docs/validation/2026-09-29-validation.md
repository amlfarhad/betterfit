# Calculation and ingestion validation

Verified 2026-09-29 on macOS with Python 3.14.2 and Swift 6.4. Checked-in fixtures are synthetic; personal measurements remain in `.private/google-health/`.

## Results

| Layer | Result | Establishes |
| --- | --- | --- |
| Python audit, normalization, cache and sync | 44 tests passed | Queries, pagination, private storage, transactional replacement, corrections/deletions, idempotence, failed/stale refresh handling, sources, DST, HR integration and snapshot consistency |
| Native Swift engine | 34 tests passed | Formula goldens, schema validation, nulls, quality gates, calibration, coverage, circular sleep timing, history isolation and numeric limits |
| Independent numerical reference | 131 assertion groups passed, including 103 age cases | Agreement with separately written Python/Decimal calculations and declared custom score behavior |
| Real account integration | Reconciled reads and native replay succeeded | Actual scoring inputs pass through the implemented pipeline; statuses are in the private report |
| Independent reviews | Findings fixed; no remaining P1/P2 in final reviewed changes | Additional engine/spec and cache inspection, not proof that no defects exist |

Maximum absolute age difference from the 50-digit Decimal reference was `2.842170943040401e-14` years, within `1e-9` tolerance. Three fixed goldens plus 100 seeded age/step combinations were checked. Other reference assertions cover Sleep, Recovery maturity and HR zone/display boundaries. [Machine-readable results](reference-results.json).

The live workflow replayed a snapshot, repeated reconciled retrieval to check unchanged records, and replayed again after cache fixes. Synthetic correction/deletion tests complement these reads; no account data was changed to manufacture a correction. The final refresh detected a changed HR snapshot and replayed it successfully, but its latest measurement timestamp did not advance. This verifies retrieval/recalculation of changed cloud data, not delivery of a new live reading or bounded device-to-app latency.

## Regression coverage

- A last-page failure cannot commit a partial response or erase healthy measurements.
- Successful empty windows remove deleted records; equivalent completed coverage stays idempotent.
- Stale overlapping responses and moved named records cannot overwrite newer state.
- Failure in one window stays visible after success elsewhere; late failures cannot poison newer success.
- Expanded query coverage and changed profile age invalidate scores even if samples are unchanged.
- A WAL read snapshot binds records, coverage, profile age, freshness and revision during concurrent writes. Input embeds provenance atomically.
- Missing readings never become zero steps, zero Strain, neutral Recovery or an extrapolated age week.
- Local-day lengths, midnight and seven consecutive closed dates are tested; unsupported travel mismatches are flagged.
- HR load is duration weighted; gaps over 60 seconds and unobserved trailing time are excluded.
- Baselines exclude current/future, wrong-source, unclosed and relevant flagged observations.

## Reproduce

```sh
python3 -m unittest discover -s tests -v
CLANG_MODULE_CACHE_PATH=.build/clang-cache swift test \
  --disable-sandbox --disable-xctest --cache-path .build/cache \
  --scratch-path /private/tmp/fibit-swift-tests \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
python3 scripts/validate_reference.py \
  /private/tmp/fibit-swift-tests/out/Products/Debug/metrics-cli \
  --output docs/validation/reference-results.json
```

The Swift command is specific to this Command Line Tools installation: it lacks XCTest, so identical assertion bodies run via Swift Testing. Scratch builds avoid iCloud Finder metadata that prevents signing. With full Xcode, use the standard XCTest command in [the engine API](../engine-api.md). Missing full-Xcode framework-path warnings did not prevent compilation or execution of all 34 tests.

## Remaining limits

Software tests verify the equation and product rules. They do not validate Fitbit Air transfer to the paper's cohorts, individual clinical age accuracy, longitudinal rejuvenation or clinical utility of custom scores. Sample SD remains an explicit convention rather than author-confirmed preprocessing. No personal confidence interval is available.

Full Xcode/iPhone execution, native OAuth/Keychain, foreground scheduling, background tasks, APNs, widgets and measured phone comparison with Google Health remain app-integration work. Fresh API reads do not prove the tracker just synced. Current scopes do not expose device last-sync diagnostics. Desktop OAuth remains in testing mode with its documented refresh-token lifetime.

Private results: `.private/google-health/engine-validation.md`, `engine-input.json`, `engine-output.json`, `sync-status.json`. The provenance sidecar is a convenience copy; embedded input provenance is authoritative. No automatic scheduler, relay or frontend is installed.
