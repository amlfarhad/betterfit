# BetterFit metric interpretation and Strain audit

Verified 2026-10-02. `Sources/FitbitMetrics/BetterFitInsights.swift` is a deterministic interpretation layer; it does not alter `MetricsEngine` score equations. All examples below are synthetic, with a configured maximum heart rate of 200 bpm. No account data was used.

## Why 18, 18.5 and 21 can appear

The existing `edwards-app-strain-1.0.0` engine applies a weight to every observed heart-rate interval across the day:

| Percentage of maximum heart rate | Weight | Example at maximum 200 bpm |
|---|---:|---|
| Below 50% | 0 | Below 100 bpm |
| 50% to below 60% | 1 | 100 to below 120 bpm |
| 60% to below 70% | 2 | 120 to below 140 bpm |
| 70% to below 80% | 3 | 140 to below 160 bpm |
| 80% to below 90% | 4 | 160 to below 180 bpm |
| At least 90% | 5 | At least 180 bpm |

`load = sum(observed minutes × zone weight)`

`Strain = min(21, 21 × ln(1 + load / 20) / ln(31))`

The zone weighting is the inherited Edwards-style convention. The logarithmic display scale and its constants are this app's heuristic, not a published validation or WHOOP's proprietary Strain formula. The product has no evidence that these values identify danger, safety, overtraining, injury, or readiness for a particular workout. The upper endpoint only means the display mapping has reached its cap.

| Display score | Weighted minutes | Minutes at weight 1 | Minutes at weight 3 | Minutes at weight 5 |
|---|---:|---:|---:|---:|
| 18.0 | 359.61 | 359.61 | 119.87 | 71.92 |
| 18.5 | 391.95 | 391.95 | 130.65 | 78.39 |
| 21.0 | 600.00 or more | 600.00 | 200.00 | 120.00 |

Consequently, a long period at 50–60% of maximum can yield 18 without any observations in higher zones. All-day accumulation includes daily movement and other causes of increased heart rate; the input does not identify workout time or the cause of an increased heart rate. Above 600 weighted minutes, additional load no longer changes the displayed score. There was no arithmetic defect in the audited mapping; interpretation and presentation caused the confusion. The score stays available in detail for continuity.

When a measured maximum is absent, the existing engine uses `208 − 0.7 × age`. This is a population equation studied in healthy adults, not an individual's measured maximum. The original study supports the equation's provenance, not the app's load mapping, all-day use or safety classification. [Tanaka, Monahan and Seals, JACC 2001](https://www.jacc.org/doi/full/10.1016/s0735-1097%2800%2901054-8).

## Activity shown in measured units

- `zoneMinutes[0...5]` keeps the six observed duration totals; `elevatedMinutes` is their sum excluding zone 0 (at least 50% of configured/estimated maximum). `higherIntensityMinutes` totals zones 3–5 (at least 70%). These are app-defined HR bands, not Fitbit Active Zone Minutes.
- Coverage is observed seconds / elapsed seconds, bounded at 100%. Missing, invalid or conflicting HR produces missing minutes and missing coverage, never a synthetic zero. Valid recorded time entirely in zone 0 produces a genuine zero elevated total.
- Observed minutes remain visible under incomplete coverage, accompanied by the coverage percentage. The unchanged legacy engine requires at least 80% coverage to emit its score; BetterFit requires at least 90% full-day coverage for a completed-day comparison.
- Baselines use the previous 28 calendar dates, excluding the selected date, unclosed dates, other sources, invalid HR and days with less than 90% full-day coverage. At least seven eligible observations are required. Day duration comes from ingestion so 23/25-hour local dates are handled by their actual duration.
- An open day is described as **so far**. It is never classified as below the completed-day range. Prior completed-day ranges may still be displayed explicitly as context.

## Personal baseline convention

For each scalar, the personal baseline is its prior median with the linearly interpolated 10th and 90th percentiles as the displayed range. For sorted values `x[0...n-1]`, percentile `p` interpolates at index `(n−1) × p`. The current observation is compared with those limits; its deviation is current value minus the median, in the original unit. The median reduces the influence of extremes on the center. The percentile range can still be unstable with a small sample, particularly near the seven-day minimum; it is an empirical summary, not a statistical confidence interval or a medically validated range.

HRV, resting HR, oxygen, respiration and skin temperature each have their own independent history of at least seven valid same-source readings on closed prior dates within 28 days. The app never replaces absent values with the baseline. A known signal-specific quality issue suppresses that signal; an unrecognized issue fails closed. Wording is **above/below/within your usual range**, with no diagnosis or health all-clear. Current daily vital values can be displayed because these are daily observations rather than an accumulated activity total.

| Metric | Stored/displayed unit | Interpretation |
|---|---|---|
| Heart rate variability | RMSSD, milliseconds | Difference from the user's own prior median |
| Resting heart rate | beats/minute | Difference from the user's own prior median |
| Oxygen saturation | percent | Native percentage; deviations are percentage points |
| Respiratory rate | breaths/minute | Daily main-sleep mean |
| Skin temperature | °C | Nightly skin mean; deviation from the app's own prior median |

The Google Health REST schema specifies `averagePercentage` on a 0–100 scale, `breathsPerMinute`, and `nightlyTemperatureCelsius` as a nightly skin mean. The API also provides its own optional temperature baseline, which this app does not substitute for the explicitly defined 28-day baseline. Skin temperature is not core temperature. [Google Health data point schema](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints#DailyOxygenSaturation).

## Sleep quantities

- The displayed duration is measured asleep minutes. Efficiency is `100 × asleepMinutes / periodMinutes`, using the reported main-sleep period rather than inferring time in bed. Neither is a clinical sleep evaluation.
- Seven-day shortfall is `sum(max(0, chosenTargetMinutes − asleepMinutes))` for the seven calendar dates ending on the selected date. It is a bookkeeping convention against the chosen target, not a physiological estimate of sleep debt or a prediction of recovery time. Longer nights do not cancel another night's shortfall.
- Only valid, same-source, complete known nights count. A timestamped night must end on or before `input.generatedAt`; a legacy night lacking timestamps counts only on a closed date. Missing nights remain missing. The UI receives both known-night count and window size; a partial window is never silently extrapolated to seven nights. No complete nights yields a missing shortfall, not zero.
- Regularity is the shortest circular difference in minutes between the selected sleep midpoint and the circular mean of at least seven prior complete same-source nights in 28 days. Crossing midnight therefore does not create a nearly 24-hour error. A circular mean with undefined direction yields no deviation.
- Stages remain the provided light/deep/REM durations. No missing stage is invented, and classic restless time is not converted to REM. Google's sleep schema distinguishes actual stage data and main-sleep summaries. [Google Health sleep guide](https://developers.google.com/health/data-types/sleep).

## Verification and computational scope

Synthetic tests cover zone boundaries, unchanged score examples, missing/conflicting signals, coverage, completed-day source/date fences, current-day labeling, percentile values, independent vital histories/units, complete-night shortfalls, midnight regularity and deterministic output independent of input order. Existing engine tests remain the formula regression reference. Decimal and fractional-duration regressions specifically prevent equal readings being classified outside their own range due to floating-point interpolation, and prevent input ordering from changing sleep shortfall totals.

Each selected-date evaluation makes bounded work over at most 28 prior calendar days of bins plus the selected date, and five short scalar histories. It scans the input dates to form the relevant window; it does not recalculate the engine's entire score history. The UI caches the result until input/date changes. `generatedAt` supplies the clock for completion checks, preserving reproducibility.

Release verification on 2026-10-02: 16 BetterFit interpretation tests plus 34 existing engine tests passed (50 total). Sources/tests were copied without modification to an isolated `/private/tmp/betterfit-insights-harness` package while parallel UI work temporarily prevented a whole-package build. Command: `DEVELOPER_DIR=/Users/amlfarhad/Downloads/Xcode.app/Contents/Developer swift test --package-path /private/tmp/betterfit-insights-harness -c release --scratch-path /private/tmp/betterfit-insights-tests/isolated`. Whole-app verification remains a separate integration step.

The final independent integration check also ran all 15 new data tests against the settled AirSync and MetricsEngine sources (65 total tests passed). Review caught new vital/stage issue flags being treated as unknown by the legacy engine; the data implementation now routes them only to consuming signals, while retaining all legacy/unknown issue handling and the existing equations. The six optional vital issue flags and new stage flag no longer change unrelated movement-age eligibility.

A Release benchmark on this development Mac evaluated 28 selected dates from 70 synthetic days with 1,440 HR bins/day and timestamped sleep: four passes took 24.2–24.6 ms each in total (under 0.9 ms/date on average). The first implementation took 976–1,015 ms for the same workload because it repeatedly constructed `ISO8601DateFormatter`. Using the pure value-type ISO8601 parser removed that overhead. These development-machine measurements are not a phone frame-time guarantee.

## Build7 validation isolation correction

A bad optional stage breakdown must not suppress a valid sleep summary. Stages are still validated and hidden on failure; duration/efficiency and the Recovery sleep input remain usable. Unknown quality flags and invalid core sleep totals remain blocking. Google's optional temperature baseline/variability fields do not feed any calculation here, so they are excluded from validation of the independent nightly Celsius reading. That primary reading remains finite/range-checked; BetterFit's own personal baseline is unchanged. Actual phone status-only diagnostics reproduced both overbroad validation failures and confirmed no failed streams after correction.
