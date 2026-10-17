# Google Health inputs for the scoring engine

Status: source schema verified against a real account on 2026-09-29. Canonical normalization and the native engine are implemented; see the [exact calculation specification](../superpowers/specs/2026-09-29-calculation-engine-design.md) and [engine API](../engine-api.md). Personal values and account-specific reports remain in `.private/google-health/`.

## Canonical measurements

| Input | API field | Unit and handling |
| --- | --- | --- |
| Heart rate | `heartRate.beatsPerMinute` | bpm; preserve sample timestamp, UTC offset and source. Integrate over time, not sample count. |
| Daily resting HR | `dailyRestingHeartRate.beatsPerMinute` | bpm; retain `calculationMethod`; separate `WITH_SLEEP` and awake-only source regimes. |
| Daily HRV | `dailyHeartRateVariability.averageHeartRateVariabilityMilliseconds` | RMSSD in ms. This is the daily input candidate; do not substitute deep-sleep-only RMSSD silently. |
| Intraday HRV | `heartRateVariability.rootMeanSquareOfSuccessiveDifferencesMilliseconds` | RMSSD in ms. Preserve observation times; never substitute SDNN. |
| Sleep | `sleep.summary.minutesAsleep`, `minutesAwake`, `minutesInSleepPeriod`, stage summaries | Minutes; use processed main-sleep sessions for nightly scoring. Preserve naps separately and attribute sessions to local waking date. |
| Steps | `steps.count` | Integer count, encoded as a JSON string (protobuf int64). Preserve the interval; absent minutes are unknown without additional coverage evidence. |
| Active zone minutes | `activeZoneMinutes.activeZoneMinutes`, `heartRateZone` | Google's weighted activity minutes, not necessarily elapsed minutes. Keep separate from raw HR duration and our own strain calculation. |
| Exercise | `exercise.activeDuration`, `metricsSummary` | Active duration is a protobuf duration; parse it explicitly. Keep exercise labels and source provenance. |
| Respiratory rate | `dailyRespiratoryRate.breathsPerMinute` | breaths/minute; use daily series consistently. Sample sleep summaries may include multiple records per night. |
| Oxygen saturation | `dailyOxygenSaturation.averagePercentage` | Percentage points on the 0–100 scale; do not multiply by 100. |
| Sleep temperature | `dailySleepTemperatureDerivations.nightlyTemperatureCelsius` | °C, skin/device-derived sleep temperature; not core body temperature. Preserve reported baseline separately. |
| VO₂ max | `vo2Max`, `dailyVo2Max`, `runVo2Max` | Separate estimate types and methods. Empty responses mean no records in the queried window, not device incompatibility. |
| Heart-rate zones | `dailyHeartRateZones.heartRateZones` | Date-specific bpm boundaries. Configuration data does not prove the device was worn that day. |
| Demographics | profile `age` and any explicitly supplied model inputs | Account age is available. Do not infer sex or other missing demographics from identity. |

## Data handling decisions

1. Retain original timestamps, offsets, native dates, source metadata and retrieval time. The current adapter uses an explicitly configured IANA timezone and checks source offsets against it. Travel/offset mismatches withhold affected scores; a historical travel policy remains future work. Daily HRV already uses the user's local date. Missing zero-valued civil-time components can mean midnight under protobuf defaults.
2. Treat the current local day as incomplete. Compute completeness against the appropriate elapsed interval; do not divide every partial day by 24 hours and present it as device failure.
3. Keep measurement availability distinct from personalized baseline sufficiency. Google's calibration state is not a switch controlling our raw-data access. Four nights can support parser verification but cannot establish multi-week personal variability or validate an aging model.
4. Do not bridge large HR gaps with hours of invented readings. Specify an integration gap limit in the strain model and report excluded time. Irregular 1–5-second sampling must not give more heavily sampled periods more physiological weight.
5. Sleep short awakenings may overlap primary sleep stages. Do not add both timelines to calculate sleep duration. Start with the supplied summary, check consistency, and explicitly define any reconstruction or overlay rule.
6. Source names identify Fitbit Air in the initial audit but are not stable unique hardware identifiers. Scoring now uses API-reconciled `google-wearables` family data; this is a canonical provider stream, not proven individual-Air provenance. Raw-source records cannot enter this stream. Prefer stable record names where present; most sample types have no record name. Never append repeat imports to score inputs unchecked.
7. Preserve source corrections and `updateTime` where present. Refresh overlapping recent windows and recompute affected days after an update. The implemented cache atomically replaces fully fetched windows, preserves good records on failure, and increments score revision for payload, coverage or age changes. Export binds measurements and provenance to one SQLite read snapshot.
8. Do not treat an API-provided temperature baseline as evidence of 30 observed nights. Keep its value and provenance separate from the observed history length.
9. Parse missing, permission-denied, malformed, and zero-valued measurements into distinct states. No automatic neutral score, perfect score, or zero score for missing data.
10. Keep source API responses private. Use synthetic fixtures in source control. The current utility performs GET-only health access and OAuth token exchanges; no health-account writes or external scoring calls.

## Verified query behavior

- Sleep: `sleep.interval.end_time` with UTC boundaries.
- Exercise: `exercise.interval.civil_start_time` with civil-date boundaries. Physical start-time filtering was rejected by the live API.
- HR, HRV, respiratory sleep summaries and run VO₂ max: sample physical time.
- Daily summaries: native `.date`; underscore prefixes were accepted by the live API.
- Sleep/exercise page size at most 25; other audited types at most 10,000. Follow pagination to completion.
- The audit's broad UTC window and exercise's civil window are availability probes, not interchangeable day boundaries for scoring.

## Implemented calculations

Recovery uses robust personal log-RMSSD/RHR baselines and a sleep deficit term; Strain integrates Edwards-style HR zones with a custom display scale; Sleep scores main-sleep duration and efficiency, with regularity reported separately. Exact weights, gates, gap limits and version identifiers are in the implementation specification. These custom app scores are not claimed to reproduce WHOOP or provide clinical readiness measures.

Biological Age is implemented using the published MoveIt! Age equation and seven closed consecutive days. The [model selection](2026-09-29-age-model-selection.md) documents full coefficients, sample-SD convention, coverage guards and Fitbit-transfer limitations. No arbitrary age bonuses, imputed laboratory values or paid inference service are used. Software verification does not establish clinical validity.

## Sources

- [Data-point schemas and units](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints)
- [List filters and pagination](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/list)
- [Sleep and overlapping awakenings](https://developers.google.com/health/data-types/sleep)
- [Data types and storage resolution](https://developers.google.com/health/data-types)
