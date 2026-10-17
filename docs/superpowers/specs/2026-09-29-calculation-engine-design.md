# Calculation engine and freshness design

Amal explicitly authorized implementation and validation on 2026-09-29. This continues the approved scoring-before-frontend phase. No additional approval gate is needed for local code and tests. Keep the existing workspace and audit files; no frontend, paid deployment or automatic monitoring is part of this change.

## Architecture

Use a Foundation-only Swift package, `FitbitMetrics`, for deterministic calculations that the eventual native iPhone app can import directly. A small command-line target consumes versioned JSON and writes score results. The existing Python audit tool gains source-aware ingestion, a private SQLite snapshot cache and a canonical exporter for real-data validation. Python is the Mac inspection/sync harness; the Swift engine is the shared iOS component. iPhone OAuth, background tasks, APNs and widgets remain app integration work.

All scores include a model version, status, optional numeric value, input breakdown and machine-readable reasons. Null values are explicit. Availability, sample coverage, baseline maturity, sync age and scientific validity remain separate concepts. No health data or credentials enter source-controlled fixtures.

## Canonical input schema v1

`InputBundle`: `schemaVersion` integer 1; `generatedAt` ISO UTC string; `asOfDate` ISO local date; `ageYears` number; `sleepTargetMinutes` number (default 480); optional `measuredMaxHeartRate`; array `days`.

`DailyInput`: `date`; `sourceKey`; `dayDurationSeconds`; `elapsedSeconds`; `isClosed`; `steps` optional number; `stepsComplete` boolean; `heartRateBins` array of `{bpm, seconds}`; optional `rmssdMs`, `restingHeartRate`; optional `sleep` `{asleepMinutes, periodMinutes, midpointMinute}`; array `issues`.

Daily dates are unique and valid ISO dates. Numeric inputs must be finite. HR bins aggregate nonoverlapping measured intervals, not sample counts. The exporter uses a configured IANA timezone, verifies record UTC offsets match it, splits intervals at local midnight, and marks conflicts/unsupported timezone changes in `issues`. `elapsedSeconds` ends at the earlier of capture time and local day's end; daylight saving days may have 23 or 25 hours. Closed dates must precede `asOfDate`. Source selection is the explicit Google-authoritative `google-wearables` reconciled stream. This selects a wearable family, not an individual Air; the API does not return hardware identity on these reconciled points. Raw records are rejected at normalization so they cannot be mislabeled or mixed into that stream. Source keys identify the policy plus RHR calculation method, not a physical device. Current audit records identify Air; future additional Google wearables can change the provider-combined stream.

`stepsComplete` means a successful full-day fetch with no overlaps or conflicting records and an available step total; biological-age scoring separately requires at least 90% HR time coverage. This is a conservative app completeness screen, not validated wear-time classification. A completely absent step series remains null rather than an invented zero. Corrected snapshots replace the previous query window atomically; failed or partially paginated queries cannot delete old data or advance freshness.

## Sleep v1 (transparent app heuristic)

Sleep score = `80 * min(asleepMinutes / targetMinutes, 1) + 20 * min((asleepMinutes / periodMinutes) / 0.90, 1)`, bounded 0–100. Reject nonpositive period, negative duration, asleep > period or >24-hour sleep periods. The default eight-hour target is a configurable product default; the scientific adult recommendation is at least seven hours, not exactly eight for everyone. Extra sleep earns no extra bonus and receives no arbitrary penalty. Use processed main sleep on local waking date; preserve short-awakening overlaps by using Google's summary, not adding the overlapping stage timelines.

Report sleep timing regularity separately, after at least seven prior valid midpoints in the previous 28 calendar days: `100 * exp(-0.5 * (circular deviation in minutes / 60)^2)` against a circular baseline. It is not included in the core sleep score, so early history does not silently change score weights.

## Recovery v1 (transparent app heuristic)

Require today's positive RMSSD, resting HR and valid sleep, plus at least seven prior paired RMSSD/RHR nights from the same source in the preceding 28 calendar days. Exclude today and all future dates from baseline. Use log RMSSD; robust center is median; robust scale is `max(1.4826 * MAD, floor)`, with floors 0.10 log-ms and 3 bpm. Define `h = clamp((ln(todayHRV)-median(ln(priorHRV)))/scaleHRV,-3,3)` and `r = clamp((median(priorRHR)-todayRHR)/scaleRHR,-3,3)`. Score is `clamp(70 + 10*(0.7*h+0.3*r) - 20*(1-min(asleep/target,1)),0,100)`.

Fewer than seven prior valid nights returns `calibrating` and null value; 7–20 returns `provisional`; >=21 returns `available`. These are design thresholds and weights, not a validated clinical readiness model or reproduction of WHOOP/Google/Bevel scores. No exercise prescriptions or diagnosis follow from the score.

## Strain v1 (cardiovascular load)

Use measured HRmax if configured; otherwise Tanaka `208 - 0.7*ageYears`, flagged as an estimate. Weighted HR zone minutes use Edwards-style weights: <50% HRmax=0; [50,60)%=1; [60,70)%=2; [70,80)%=3; [80,90)%=4; >=90%=5. Raw observed load is sum(minutes × weight). Map to a 0–21 display scale with `min(21,21*ln(1+load/20)/ln(31))`. The display mapping and application to all-day HR are our product adaptation; this is not WHOOP's proprietary formula and does not measure strength/muscular load.

The exporter integrates left-held HR only between consecutive valid samples separated by <=60 seconds; longer gaps and the trailing unsupported sample contribute no time. Reject duplicate conflicting samples and impossible numeric inputs. Report raw load and coverage even when a display score is withheld. Require >=80% integrated HR coverage for a score; 80–<90% is `partial`, >=90% closed days `available`, >=90% current day `live`. Empty HR remains null, never a perfect or zero-effort day.

## Biological age v1

Candidate selected for final verification: MoveIt! Age, Lu et al., DOI `10.1007/s11357-025-01999-7`. Published final equation: `4.2390852 + 1.0824163*age - 0.0012294*maxDailySteps + 0.0015739*sdDailySteps`. No additional delta normalization may be applied. Use sample SD (n−1) as an explicitly documented R-convention inference, pending any author clarification. The app labels the result as a movement-derived biological-age estimate; it is a proxy developed against PhenoAge, not measured tissue age or laboratory PhenoAge.

Require the seven immediately preceding consecutive closed local dates, successful step data, no disqualifying issues, one consistent source, and >=90% integrated HR coverage on each date. Do not select the best seven days from a longer window or fill gaps with zeros. Require adult age >=20, within the general input safety limit of 120 years; the paper does not establish an exact complete-case upper-age boundary. Output outside 0–120 is withheld under a product plausibility guard rather than clipped; that guard is not a published validation range. Recompute when the eligible window changes or source corrections arrive. No fabricated CI or per-factor causal rejuvenation claim. Publication validation and our implementation tests are reported separately. Final source/license review is in the model-selection research note.

## Freshness and synchronization

Foreground: immediate stale-cache refresh when opened, manual refresh, then a rate-limited refresh opportunity no more often than once per 60 seconds while visible. Background: opportunistic iOS refresh; optional signed Google Health webhook relay to APNs for better latency. Neither guarantees immediate device uploads or background execution. No server deployment is authorized or needed to test the engine.

Store `lastAttemptAt`, `lastSuccessAt`, `latestMeasurementAt`, and device `lastSyncTime` separately. Retry transient errors with bounded backoff and honor server rate limits. Snapshot replacement commits only after every page succeeds. Re-fetch a rolling three-day window for edits and late data, with a 32-day repair window at least weekly and an initial 32-day import. A notification is an invalidation hint, not measurement data. Older changes require explicit historical refresh; document this bound rather than claiming complete historical push coverage.

## Validation

Golden vectors for the published age equation; sample vs population SD sensitivity; null/NaN/invalid ranges; seven-day continuity and collection progress; no future leakage or mixed sources; recovery baseline floors/outliers; sleep zero/overlap consistency; HR zone boundaries, sample-rate invariance, gaps, midnight and DST; repeated import idempotence; atomic snapshot replacement and rollback; deletion by successful empty response; partial failure freshness; synthetic notification duplicate handling in the sync policy; real-data replay with all private outputs preserved.

Success means tested code and documented limits, not clinical validation of an individual's biological age. No front end begins until these artifacts are reviewed for correctness.
