# Native Google Health sync

`AirSync` is a Foundation-only Swift 6 adapter for the existing `FitbitMetrics` engine. It has no third-party dependency, auth UI, Keychain implementation, or background scheduler. `AirAuth` supplies an async access-token closure; `AirUI` decides when to request a refresh.

```swift
let sync = NativeHealthSync(cacheURL: privateCacheURL) {
    try await authorization.accessToken()
}
let saved = try await sync.load(timeZone: .current, sleepTargetMinutes: 480)
let current = try await sync.refresh(timeZone: .current, sleepTargetMinutes: 480)
let scores = current.scores
try await sync.clear()
```

`refresh(now:timeZone:sleepTargetMinutes:force:)` coalesces concurrent calls. Automatic refresh attempts are at least 60 seconds apart once a profile is cached; `force` bypasses that interval without forcing a larger history repair. Cancellation propagates to requests and prevents committing a partial in-progress run. `clear()` cancels the refresh before removing its cache. The actor does disk I/O, normalization and score evaluation off the UI actor. Each immutable snapshot carries matching input and scores, so presenting it does not evaluate the engine again.

The supplied `now` is the refresh's planning time. The live implementation captures a completion time after network responses, so observations uploaded during a download are not mislabeled as future data. The internal transport and clock injections keep regression tests deterministic.

## Network scope and schedule

Only GET requests to `https://health.googleapis.com/v4/` are built. The paths are a closed set: `users/me/profile` and the reconcile endpoints for steps, heart rate, sleep, daily HRV, and daily resting HR. All requests select `users/me/dataSourceFamilies/google-wearables`. Raw data-point endpoints, arbitrary hosts/paths, writes, nutrition, and GPS are absent. A URLSession delegate refuses redirects; response host/path checks also fail closed. An ephemeral session disables cookies and URL caching.

The initial request covers 32 local calendar dates including today, in chunks of at most seven local dates. Physical predicates use exact UTC instants corresponding to local boundaries; daily summary predicates use local calendar date strings. DST days therefore keep their true duration.

Afterward, eligible foreground refreshes fetch the last two physical hours through the latest whole second and yesterday/today's daily summaries. Aligning the query and replacement boundaries avoids submillisecond rounding admitting a sample outside the validated window. Every 15 minutes the adapter reconciles three local dates. Every seven days, or after more than two days without a completed download attempt, it repairs the 32-date window again. Pull-to-refresh follows that same repair schedule. Existing older cached observations remain local; this version has no retention-pruning UI or long-term storage benchmark.

Completed attempt timestamps are separate from all-success timestamps. A partial failure therefore does not repeatedly trigger a full download of healthy history. Unresolved windows are added only to the affected metric's next request, unioned with its scheduled windows and split into chunks of at most seven local days. Daily-summary retries align to current local-day boundaries after a timezone change. Older cache files without attempt timestamps fall back to their existing success timestamps.

Up to three independent metrics download concurrently. Each metric's windows and pages remain ordered. Validation and staging remain on the sync actor; the previous committed cache is preserved until the refresh finishes. This reduces serial network waiting without unbounded request concurrency.

Every page must finish before its metric/window is replaced. A repeated or malformed token, 200-page limit, more than one million points in a window, malformed/null collection, or oversized response rejects the window. Each response body is bounded at 25 MB after download. URLSession timeouts are 45 seconds per request and 60 seconds per resource. Transport errors and HTTP 429/500/502/503/504 have at most four attempts, with Retry-After capped at 30 seconds. HTTP 401 invokes the token provider once again; persistent authorization failure requires reconnecting. Tokens and API error payloads are never logged or cached by AirSync.

## Cache and freshness

One actor owns the cache. A fully fetched window replaces only records whose event lies in that half-open query interval. Steps use interval start, sleep uses interval end, HR uses sample time, and summaries use their native date. Stable named identity also removes a record's former position when a correction moves it between windows. Anonymous identity uses event time and interval end. Exact repeats are idempotent; conflicting records sharing an identity reject the response. An empty successful window deletes previously cached observations in that window.

The cache validates the complete response before replacement. A failed metric/window retains its prior observations and coverage while successful independent windows can update. Failures stay visible until successful windows from the current attempt jointly cover the entire failed interval; unrelated success or old coverage cannot hide them. Successful query coverage is unioned for steps completeness. Missing step records remain missing, including in successfully checked empty windows.

The full cache file includes observations, query coverage, profile age, source policy, revision, attempts, successes, and failures. It is atomically replaced, mode 0600, excluded from backup, and uses iOS complete-until-first-authentication file protection. Its directory is created mode 0700. Direct file/parent symlinks are rejected. The caller must choose an app-owned private Application Support directory. No account cache is bundled with the app.

`SyncSnapshot.freshness` reports:

- `checkedAt`: completion of the latest attempted refresh.
- `lastSuccessfulSync`: completion of the latest refresh with every requested metric/window successful.
- `lastMeasurementAt`: latest nonfuture physical observation across HR, steps and sleep. This is **not** a device sync/upload timestamp, and daily dates are not converted into fabricated measurement times.
- `failures`: sanitized per-window or profile error codes and times.
- `revision`, `sourcePolicy`, and the current-profile age provenance.

The Google profile age is required, finite, and in 18–120. It is checked initially, daily, and on explicit refresh. An invalid/missing age fails with a reconnect/profile message and preserves previous measurements. No age is inferred. Changed age increments the revision. Timezone and sleep-target changes re-normalize the raw cache, so derived values are not reused under incompatible inputs. Unsupported cache versions or source policies fail instead of mixing streams.

## Normalization and acceptance policy

`HealthNormalizer.normalize(records:ageYears:now:timeZone:sleepTargetMinutes:completedWindows:)` ports the audited Python adapter. It accepts Sendable `JSONValue` records, never `Any` across actors. Source-bearing raw records are rejected. It preserves numeric strings used by protobuf int64 fields, rejects booleans as measurements, and applies the same sleep target range of 360–720 minutes.

HR intervals integrate the left sample only when both bounding samples are valid, unconflicted, and at most 60 seconds apart. Gaps are not interpolated; intervals split at local midnight. Step intervals cannot be divided across local midnight without inventing timing. Sleep uses processed main-sleep summaries, assigns the wake date, and derives the circular midpoint from the actual interval. Daily RHR calculation method participates in the source key. Offset mismatches, future observations, conflicts, overlap, missing measurements, and model coverage gates remain explicit. Protobuf fractional timestamps are truncated to microseconds to match Python datetime; invalid Gregorian dates and 24:00 timestamps are rejected.

The **cache acceptance boundary is stricter than Python's broad structural store validator**: replacements must satisfy the normalizer's HR/RHR 25–250 bpm and average RMSSD 1–200 ms domains, and required intervals must be positive and no longer than 24 hours. Processed sleep summaries must be internally consistent. A newly normalized window containing an `invalid_*` dependency issue is rejected before commit. This prevents a malformed/out-of-domain replacement from erasing healthy saved measurements. The pure normalizer still reports those issues for direct audit/parity inputs, preserving the audited Python behavior. These are source-quality domains, not a clinical plausibility claim.

## Verification

The Swift Testing suite includes pagination, retry limits, redirect rejection, cancellation, concurrent coalescing, throttle/schedule behavior, corrections/deletions, persistence, partial failure preservation, physical-vs-check freshness, invalid replacement preservation, completion-clock behavior, source rejection, offset/conflict flags, sleep summaries, DST, and microsecond timestamp semantics.

An optional private parity test reads only a temporary fixture. Create it locally from the existing SQLite cache with:

```sh
python3 tests/AirSyncTests/make_parity_fixture.py \
  --database .private/google-health/cache.sqlite3 \
  --output /private/tmp/form-air-sync-private-parity/fixture.json
```

The helper opens SQLite read-only and creates the fixture mode 0600. Run the Swift tests with `AIRSYNC_PARITY_FIXTURE` set to that path. Without that environment variable, the private test is skipped. Neither fixture nor private outputs belong in Git. The test compares normalized input and engine output at absolute numeric tolerance 0.000001; capture timestamp formatting allows under 1 ms because the native ISO renderer uses milliseconds. It emits only an opaque mismatch on failure, never account measurements.

On 2026-09-29, 26 AirSync tests passed on the Command Line Tools host, including the real local SQLite/Python parity check (9–19 seconds for a 27 MB private fixture). Targeted builds used the already-installed Swift Testing macro plugin and an external temporary scratch directory, as described in `docs/engine-api.md`. The optional fixture contains account data and was not committed. No live OAuth/API request, iPhone memory/performance benchmark, or background execution reliability is established by these tests. iOS integration/build/device validation is reported separately by the app work.

The 2026-10-02 performance pass added bounded-concurrency, manual-refresh, partial-failure scheduling, timezone-retry, split-window recovery, score handoff and cancellation-after-staging regressions. Synthetic 90,000-record timing results, signed phone deployment and remaining measurement limits are recorded in [performance validation](validation/2026-10-02-performance.md).
