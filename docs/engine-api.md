# Native calculation engine

`FitbitMetrics` is a Foundation-only Swift package for iOS 16+ and macOS 13+. It has no network, model-service, or third-party runtime dependencies. All fixtures are synthetic. Swift 6.4 was used for local verification.

The public entry points are:

```swift
let input = try JSONDecoder().decode(InputBundle.self, from: data)
let result: ScoreBundle = try MetricsEngine.evaluate(input)
let outputJSON: Data = try MetricsEngine.evaluate(json: data)
```

`InputBundle`, `DailyInput`, `HeartRateBin`, and `SleepInput` have public native initializers as well as Codable support. Input validation is applied to both entry points, including nonfinite values constructed directly in Swift. Results retain calculation precision; presentation rounding belongs to the app.

## Command line

```sh
CLANG_MODULE_CACHE_PATH=.build/clang-cache swift run \
  --disable-sandbox --cache-path .build/cache \
  --scratch-path /private/tmp/fibit-swift-tests metrics-cli INPUT.json
```

Pass `-` instead of a filename to read standard input. Successful output is sorted-key JSON on stdout, ending in a newline. Failures write a structured JSON error to stderr, emit no score document, and exit 1. Post-decoding validation errors include a machine-readable `error`, `path`, and `message`. Malformed JSON, missing required keys and wrong JSON types return a generic `invalidJSON` error without a field path or echoed private measurements. `generatedAt` is copied from the capture timestamp, never replaced with calculation wall-clock time.

## Input v1

The canonical schema is defined in [the design](superpowers/specs/2026-09-29-calculation-engine-design.md). The engine requires its fields and types, with optional measurements decoded from omitted keys or JSON null. Omitted/null `sleepTargetMinutes` defaults to 480. Unknown object fields are ignored for forward-compatible metadata; unsupported `schemaVersion` is rejected.

Dates must be valid, unique `YYYY-MM-DD` local dates, no later than `asOfDate`. A closed day precedes `asOfDate` and has `elapsedSeconds == dayDurationSeconds`, within one microsecond of integration rounding. A nonclosed historical day cannot receive a `live` strain status. Capture timestamps must be actual Gregorian dates with a `T` separator and UTC `Z`, optionally with 1–9 fractional second digits.

All numbers must be finite. The engine accepts general input ages 0–120; the age model requires at least 20. Steps are nonnegative, HR/RMSSD/RHR and measured HRmax are positive, and sleep targets are in `(0,1440]` minutes. Local-day duration is positive and at most 48 hours; elapsed seconds are in `0...dayDurationSeconds`. This includes 23-, 24-, 25-hour and fractional-hour DST days. HR-bin durations are nonnegative and their sum cannot exceed elapsed time by more than one microsecond. Sleep period is positive and at most 1440 minutes, asleep duration is within the period, and midpoint is in `[0,1440)`.

These native numeric limits protect arithmetic and structural consistency. They are not a clinical plausibility classifier. The Python ingestion layer applies its narrower source-specific physiological/data domains. The engine does not reconstruct raw intervals, prove nonoverlap from aggregated bins, infer timezone correctness, or independently authenticate a source. It relies on the adapter's interval validation and issue flags. A source key identifies a selected canonical stream/policy, not proven physical Fitbit Air provenance.

Invalid raw values reject the entire bundle with `InputValidationError`. Missing measurements are valid inputs and yield null scores with reasons. Finite but extreme arithmetic cannot emit NaN/Infinity; an unrepresentable derived result becomes `outOfDomain` and identifies `arithmeticOverflow`.

## Output v1

```text
ScoreBundle
  schemaVersion: 1
  generatedAt: capture timestamp
  asOfDate: local date
  modelVersions: {sleep, sleepRegularity, recovery, strain, biologicalAge}
  days: [DailyScores], sorted ascending by date
  biologicalAge: BiologicalAgeResult
  diagnostics: [{code, date?, message}]

DailyScores
  date, sourceKey
  sleep, sleepRegularity, recovery, strain: Score

Score
  value: number | null                  (null is always explicit)
  status: ScoreStatus
  modelVersion: string
  reasons: [machine-readable string]
  components: {componentName: number}  (finite numbers only)

BiologicalAgeResult
  label: "movement-derived biological-age estimate"
  referenceURL: DOI URL
  score: Score
  collection:
    requiredDays: 7
    eligibleDays: number
    windowStart, windowEnd: local dates
    days: [{date, eligible, reasons}]
```

Statuses are `available`, `unavailable`, `calibrating`, `provisional`, `partial`, `live`, `insufficientCoverage`, and `outOfDomain`. Availability and scientific validity are separate: a numerically available age result still carries the movement-proxy and Fitbit-validation limitations.

Model versions are `app-sleep-1.0.0`, `app-sleep-regularity-1.0.0`, `app-recovery-1.0.0`, `edwards-app-strain-1.0.0`, and `moveit-age-2025-sample-sd-1.0.0`. A formula, preprocessing, or denominator change requires a new model version. Input/output schema versions change for incompatible contract changes.

## Quality flags and history

Unknown issues, including common `timezone_offset_mismatch` and `future_observation`, withhold all daily scores. Known flags are scoped to dependent scores:

| Issue | Withheld scores |
| --- | --- |
| `invalid_sleep`, `multiple_main_sleeps` | Sleep, sleep regularity, recovery |
| `invalid_heart_rate`, `conflicting_heart_rate` | Strain |
| `invalid_rmssdMs`, `conflicting_rmssdMs`, `invalid_restingHeartRate`, `conflicting_restingHeartRate` | Recovery |
| `invalid_steps`, `overlapping_steps` | Biological age only |

Every issue disqualifies the affected date for age collection. All supplied issues also appear in bundle diagnostics. Coverage gates use the same one-microsecond duration tolerance as input validation to keep fractional interval partitioning from changing threshold status. A blocked strain still reports observed HR load/coverage components for inspection; its score remains null.

Recovery and regularity histories use only closed dates, the same `sourceKey`, strictly preceding the scored date, within the preceding 28 calendar days inclusive. Relevant flagged nights are excluded. Recovery needs paired positive RMSSD/RHR measurements; it does not require a sleep record for each prior pair. Sleep is required for the scored day. Prior regularity nights require valid sleep midpoints. Seven baseline nights unlock both; recovery is `provisional` at 7–20 and `available` from 21.

Circular regularity uses the mean unit vector of prior midpoints and the shortest circular distance from today's midpoint. If the baseline vector's length is at most `1e-12`, there is no stable mean direction and the result is null with `undefinedCircularBaseline`. Regularity never changes the core sleep score's weights.

Age collection uses exactly yesterday and the six dates before it. It never searches for a better seven-day window. Each date requires a closed complete day, available steps, `stepsComplete`, no issues, and at least 90% integrated full-day HR coverage. The most recent present date in that window anchors the source; other sources are ineligible. A source change therefore starts a new collection period. The count is a data-readiness indicator, not statistical confidence.

## Scientific scope and attribution

The implementation uses Lu et al.'s published [MoveIt! Age equation](https://doi.org/10.1007/s11357-025-01999-7) once, without additional normalization:

```text
4.2390852 + 1.0824163 * ageYears
          - 0.0012294 * maxDailySteps
          + 0.0015739 * sampleSDDailySteps
```

Sample SD uses denominator 6 for seven observations. This is an explicit R-convention inference, not author-confirmed replication of unavailable source code. The coefficient on variability remains positive even when that is counterintuitive. No per-factor causal rejuvenation claim, fabricated confidence interval, or clinical validity is attached. The published algorithm's Apache 2.0 plus Commons Clause/commercial-permission statement is recorded in [the research and license review](research/2026-09-29-age-model-selection.md); this original local implementation does not claim commercial clearance.

The adult minimum age of 20 is a conservative product decision. There is no fabricated upper study-age boundary. Bundle ages above 120 fail general input validation, and predicted ages outside 0–120 return null with `outsideProductDisplayRange`; this is an explicit product display guard, not a scientific validation range or value clipping.

Sleep/recovery are versioned application heuristics. Strain uses Edwards-style zone weights with an original logarithmic 0–21 display mapping; it is not WHOOP's formula and does not capture muscular load. Default HRmax is Tanaka's `208 - 0.7 * age`, explicitly flagged as estimated. All source and methodological limitations remain documented in the design and research review.

## Tests on this host

The suite in `tests/FitbitMetricsTests/MetricsEngineTests.swift` uses native XCTest when the framework is available. The package explicitly uses the lowercase `tests/` path shared with the Python suite, including on case-sensitive hosts. The installed Command Line Tools lacks XCTest but includes Swift Testing, so a small compatibility layer executes the identical assertions through Swift Testing without downloading dependencies. Full Xcode/XCTest and iOS device execution remain unverified here.

The default Swift 6.4 build engine signs test bundles; iCloud Documents adds Finder metadata to `.build`, which prevents signing. A temporary scratch path avoids that file-provider metadata. This toolchain also sometimes omits its bundled Testing macro plugin during incremental scanning, so the local test command explicitly names the already-installed plugin:

```sh
CLANG_MODULE_CACHE_PATH=.build/clang-cache swift test \
  --disable-sandbox --disable-xctest --cache-path .build/cache \
  --scratch-path /private/tmp/fibit-swift-tests \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

With full Xcode, the standard command is `swift test --disable-sandbox --cache-path .build/cache --scratch-path .build`. Keep temporary build paths unique if separate checkouts run concurrently.

The suite covers independent equation goldens; sample-vs-population SD; variability sensitivity; exact consecutive windows; adult and product output gates; nulls and collection progress; source changes; quality-flag isolation; calibration thresholds; robust baseline floors; bounded outliers; circular timing; timestamp/date/duplicate validation; native and JSON nonfinite rejection; integrated HR duration/coverage; HR zone boundaries; partition invariance; DST day lengths; source-specific baselines; and exclusion of future data. Tests verify arithmetic and declared behavior, not individual health validity.
