# Native iPhone sync design

Research date: 2026-09-29. The private Mac sync/cache/export foundation is implemented and tested; native iOS scheduling, webhooks, APNs and widgets remain a design. No server, subscriber, billing or iOS credentials were created. Desktop OAuth establishes account access, not native iOS background behavior. Measurement rules remain in [data-input-contract.md](data-input-contract.md).

**Implemented scope:** the on-demand harness fetches five scoring streams through `reconcile`, uses a private transactional SQLite cache, replaces complete query windows, tracks corrections/deletions and freshness, and exports a consistent revision to the native engine. Default initial/weekly repair spans 32 local days, covering the 28-day baseline with margin; other refreshes span three local dates. API date predicates are broadened to contain those dates and partitioned into at most seven-day queries. The 60-second foreground eligibility policy is tested, but no timer or background scheduler runs yet. This harness is deliberately a validation tool, not the eventual low-latency iOS coordinator.

## Decision and freshness boundary

Start with an iPhone-owned store and scoring engine: foreground refresh, a restrained foreground poll while visible, and opportunistic background refresh. Keep an optional notification relay behind the same sync coordinator. Add that relay only if measured background freshness justifies operating a service. No paid scoring service or user subscription is needed by this design; that does not establish that optional hosting or Apple distribution is cost-free.

The supported full-data path is:

```text
Fitbit Air → BLE → Google Health iPhone app → Google Health cloud/API
                                                   ↓ HTTPS + user OAuth
                                      native app → local store → local scores
```

Google describes BLE device syncing throughout the day and automatic syncing when its mobile app opens near the device. The cloud API supports Fitbit devices, including Air. These statements do not specify an end-to-end latency bound. ([Device syncing](https://support.google.com/googlehealth/answer/14237221?hl=en), [API overview](https://developers.google.com/health/about))

Consequently, neither polling nor a relay can fetch measurements the device has not uploaded, make Google's processing finish, or force Google Health to sync Air. The realistic target is **quickly catch up to data available through the API whenever our app executes**, with honest measurement freshness when it cannot. “Always as current as Google Health” and “live cloud heart rate” are not supported promises.

Air also supports a Bluetooth Heart Rate Profile broadcast to compatible equipment/apps. That is a separate live-HR feature, not a documented replacement for sleep, HRV, history, or full device synchronization. It is outside this design. ([Google HR sharing](https://support.google.com/googlehealth/answer/14236705?hl=en))

## Alternatives

| | Local app only: recommended first implementation | Optional notification relay |
| --- | --- | --- |
| Trigger | Launch/resume, manual refresh, foreground polling, iOS-granted background task | Same triggers plus webhook-derived silent push |
| Health credentials and measurements | On iPhone | Still on iPhone; relay handles identity mapping and change metadata only |
| Closed-app freshness | Depends on iOS opportunities | Better opportunity when cloud data changes, still depends on APNs/iOS |
| Device/cloud delay | Cannot reduce it | Cannot reduce it |
| Operations | No developer server | HTTPS endpoint, durable pending-change state, APNs credentials, monitoring, possible hosting cost |
| Recovery | Overlapping window reads and historical reconciliation | Same, plus durable dirty ranges; push alone is never the change log |

Google Health currently offers direct HTTPS webhooks through `projects.subscribers`. The published subscriber configuration has `endpointUri`, not a Cloud Pub/Sub topic. Therefore use **Google Health webhook → relay → APNs**. Cloud Pub/Sub could be an internal relay queue, but is not a required or documented native Health API delivery destination. ([Subscriber schema](https://developers.google.com/health/reference/rest/v4/projects.subscribers))

## Exact API surface

All Health paths below use `https://health.googleapis.com/v4`. Health reads use `Authorization: Bearer <user access token>`; project administration is separate.

| Purpose | Method and path | Contract |
| --- | --- | --- |
| Link cloud identity | `GET /users/me/identity` | Persist `healthUserId`; don't infer it from email. [Reference](https://developers.google.com/health/reference/rest/v4/users/getIdentity) |
| Device diagnostics | `GET /users/me/pairedDevices` | Requires `googlehealth.settings.readonly`; paginate. [Reference](https://developers.google.com/health/reference/rest/v4/users.pairedDevices/list) |
| Raw/audit records | `GET /users/me/dataTypes/{type}/dataPoints` | `filter`, `pageSize`, `pageToken`; no documented modification-time cursor. [Reference](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/list) |
| Canonical stream | `GET /users/me/dataTypes/{type}/dataPoints:reconcile` | Same time filters; optional `dataSourceFamily`. [Reference](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/reconcile) |
| Named record verification | `GET /users/me/dataTypes/{type}/dataPoints/{id}` | Supported identifiable types only. [Reference](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/get) |
| Register relay | `POST /projects/{project-number}/subscribers?subscriberId={id}` | `cloud-platform` OAuth scope and IAM `health.subscribers.create`; response is an `Operation` per REST reference. [Reference](https://developers.google.com/health/reference/rest/v4/projects.subscribers/create) |
| Inspect/configure/remove relay | `GET /projects/{project-number}/subscribers`; `PATCH` or `DELETE /projects/{project-number}/subscribers/{id}` | PATCH uses `updateMask`; preserve complete desired configs when replacing them. [REST index](https://developers.google.com/health/reference/rest) |
| Optional manual user subscription | `POST /projects/{project-number}/subscribers/{id}/subscriptions?subscriptionId={id}` | `cloud-platform` plus `health.subscriptions.create`; only for `MANUAL` policy. [Reference](https://developers.google.com/health/reference/rest/v4/projects.subscribers.subscriptions/create) |

Recommended data scopes: `https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly`, `.health_metrics_and_measurements.readonly`, `.sleep.readonly`, plus `.settings.readonly` for diagnostics and `.profile.readonly` only if required by the scoring inputs. The dotted suffixes share the same `https://www.googleapis.com/auth/googlehealth` prefix. Respect partial consent by metric. Do not request write scopes or `cloud-platform` in the consumer iOS sign-in.

Production must not sum the audit's raw `list` records unchecked. Device re-bucketing can create overlapping records; `reconcile` chooses authoritative records, including conflict resolution across devices. Source-owned edits can change interval boundaries. These are reasons to replace queried windows and recalculate affected dates. ([Data management](https://developers.google.com/health/data-management))

Proposed source policy: evaluate `dataSourceFamily=users/me/dataSourceFamilies/google-wearables` for Air-focused scoring; this selects Google's wearable family, not an individual Air. `users/me/dataSourceFamilies/all-sources` is the default and the relevant comparison for a combined Google Health view. `users/me/dataSourceFamilies/google-sources` includes Google's first-party sources. Short names alone are invalid. Version the chosen policy and backfill when it changes; do not mix raw and reconciled records in one sum. Most reconciled points have no `dataPointName`, so a universal record-ID upsert is insufficient. ([Reconcile reference](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/reconcile), [Endpoint conventions](https://developers.google.com/health/endpoints))

## Bounded local sync policy

The numbers here are initial engineering settings, not vendor guarantees; tune after instrumented iPhone trials.

1. On launch/resume, render the last committed snapshot immediately and request one refresh if the relevant snapshot was checked more than 60 seconds ago. Manual refresh can bypass that age gate, but joins an existing refresh rather than starting a second one.
2. While the app is visible and active, poll at most every 60 seconds. Prioritize latest HR/steps/activity and today's affected partitions. Stop the timer on backgrounding. Re-fetch the last two hours for fast intraday catch-up, plus pending dirty partitions; do not download all history each minute.
3. Once per foreground session, sweep today and the preceding two local dates for every granted scoring input. This catches recent sleep processing, midnight boundaries and revised daily metrics. Complete bounded partitions before marking them checked.
4. Once per elapsed day, queue a seven-day recent-window reconciliation. Once per seven elapsed days, queue reconciliation of the active 32-day scoring window, in resumable chunks. The finalized model needs 28 prior days, so 32 replaces the research draft's proposed 90-day active window. Older retained history must be labeled with its last reconciliation time and refreshed when accessed; do not call an archive current. The Mac harness implements three-day incremental and 32-day weekly repair; the additional native daily/fast-path queue remains future iOS work.
5. Register one `BGAppRefreshTaskRequest`; after each opportunity, request the next one with an earliest start 30 minutes later. This is a request, not a timer. Use at most a 20-second work budget, stop on the expiration handler, and leave remaining partitions pending. Foreground handles initial backfill and large backlog. Scheduling every 30 minutes does not mean execution every 30 minutes. ([Apple earliestBeginDate](https://developer.apple.com/documentation/backgroundtasks/bgtaskrequest/earliestbegindate), [Background strategies](https://developer.apple.com/documentation/BackgroundTasks/choosing-background-strategies-for-your-app))
6. Serialize the coordinator. Initially allow at most one API request per second and 60 attempts per minute including retries; prefer fewer. A foreground pass stops starting requests after 30 seconds or 30 requests, leaving resumable pending work. Use six-hour HR partitions when daily pages become large. A page budget being exhausted is **incomplete**, not an empty or completed window.

Google publishes 300 requests/user/minute, 120,000/project/minute and 86.4 million/project/day; its unverified-app note gives a 250-QPS project cap described as 100 users × 2.5 QPS. The one-QPS local budget stays below either interpretation. Retry `429` with backoff, and measure bytes, battery and page counts as well as request count. ([Quotas](https://developers.google.com/health/rate-limits))

No-server mode cannot discover arbitrary old edits immediately. Its declared bound is the last successful reconciliation of each stored partition. Relay mode narrows that gap but still needs this fallback after outages, missing events or an invalidated queue.

## Time, identity, correction and deletion contract

Maintain these distinct fields per metric/source-policy partition:

| Field | Meaning |
| --- | --- |
| `measurementStart` / `measurementEnd`, native date, original offsets | When the source says the observation happened; never substitute download time |
| `sourceUpdateTime` | Preserve only where supplied; not a universal ordering key or sync cursor |
| `deviceLastSyncAt` | API `PairedDevice.lastSyncTime`: last sync with Google's mobile application; diagnostic only, not evidence that every metric is processed |
| `attemptStartedAt` / `lastAttemptAt` | Local sync attempts, including failures |
| `lastSuccessfulCheckAt` | All pages for this exact predicate completed and were committed |
| `latestMeasurementAt` / `latestNativeDate` | Most recent usable observation for that individual metric |
| `snapshotRevision` / `scoreComputedAt` / `scoreModelVersion` | Which committed data and algorithm produced the displayed score |
| `pendingDirtyRanges` / `lastError` | Unreconciled work and why it remains pending |

Device timestamp semantics come from the [PairedDevice schema](https://developers.google.com/health/reference/rest/v4/users.pairedDevices). All other field names above are proposed local metadata.

Use half-open predicates, `[start, end)`. HR uses `heart_rate.sample_time.physical_time`; steps use `steps.interval.start_time`; sleep uses `sleep.interval.end_time`; exercise uses `exercise.interval.civil_start_time`; daily inputs use their native `.date`. Sleep/exercise page sizes are at most 25; other audited types at most 10,000. Follow `nextPageToken` to exhaustion using an unchanged predicate. Use actual observation offsets/native dates, not today's phone zone. A civil webhook date is not a UTC timestamp. ([List/filter contract](https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/list))

Proposed merge algorithm:

- Fetch into staging keyed by `(account, metric, source policy, canonical query partition, run generation)`. Validate schema, units, and pagination before changing committed data. Choose partitions by the API's filter anchor; include neighboring anchors for cross-midnight sessions and intervals. Do not delete “anything overlapping” a narrow window unless that query was complete for those records.
- For a completed partition, atomically replace the records selected by that same predicate. Missing prior records then disappear, which handles unnamed-sample correction/deletion. Record names, where present, are global identities within the account/type: a moved record must remove its old placement and invalidate both old and new score dates.
- Do not use payload hashes as physiological identity. Hashes may identify identical transport copies within a staged result, but source and interval changes must not leave both old and new values counted. Preserve conflicting raw provenance separately if needed for diagnostics.
- A webhook is an invalidation hint. Both UPSERT and DELETE cause an authoritative re-read of the affected partitions. A delayed DELETE must not blindly erase data that has since been recreated. For an identifiable record, a confirmed missing result plus healthy authorization can remove the cached identity; permission errors cannot.
- A fully successful empty result can replace a partition with empty data. `403`, malformed data, interrupted paging, a repeated token, budget exhaustion, and network failure cannot. Successful independent metric partitions may commit; failed ones retain their prior revision and their own stale status.
- Never let an older in-flight generation overwrite a newer commit. On a change affecting a baseline window, invalidate all dependent recovery/strain/sleep/age outputs in that window, not only the edited day's visible result. Scores retain input revisions and completeness flags. Current-day activity remains provisional.
- Refresh a token once after `401`, then stop retrying authentication errors; treat `invalid_grant` as reconnect required. Distinguish denied scope from no observations. Back off with jitter for transient errors, honor usable `Retry-After` values, and keep attempts within the work budget.

## Optional relay contract

Use an HTTPS endpoint such as `/webhooks/google-health` with a durable pending-change store. Register only the data types used by the app. `AUTOMATIC` subscriptions depend on granted scopes and have no per-user stored subscription resource. Keep subscriber administration credentials on trusted administration/hosting systems. ([Subscriber schema](https://developers.google.com/health/reference/rest/v4/projects.subscribers))

Registration requires a configured `endpointAuthorization.secret` including its scheme (for example a random `Bearer …`). The creation verification body is `{"type":"verification"}`: return `201` with correct authorization and `401`/`403` without it. Using `201` satisfies the stricter REST reference even though the guide also permits `200`. Creation uses the numeric project number, not its string project ID. ([Create reference](https://developers.google.com/health/reference/rest/v4/projects.subscribers/create))

Google's webhook contract: validate the raw-body `GOOGLE-HEALTH-API-SIGNATURE` with Tink and Google's [public keyset](https://www.gstatic.com/googlehealthapi/webhooks/webhooks_public_keyset.json); signing keys rotate every 30 days. Notifications may be single objects or batches up to 99. They carry identity, operation, type, changed intervals and sometimes a record ID, rather than measurements. Daily events may omit physical time. Return `204` promptly; other responses trigger exponential retries for up to seven days. Older undelivered events are discarded. Duplicates are possible; notification history is not backfilled on subscriber creation. The guide says account deletion/revocation does not emit data DELETE events, while its token table lists corresponding system events: do not depend on either as a guaranteed disconnect signal. ([Webhook guide](https://developers.google.com/health/webhooks))

Additional relay decisions:

1. Verify secret and signature before processing; enforce body and batch bounds; refresh cached public keys on an unknown signing key. Never verify reserialized JSON. Do not log bearer values, raw health payloads or tokens. Signature verification proves origin, not uniqueness or freshness.
2. Durably union dirty ranges and increment a per-account revision before returning `204`; downstream work runs asynchronously. If the durable write fails, return an error so delivery retries. Constant-time secret checks, bounded replay handling and rate limits are implementation requirements.
3. Deduplicate processing through idempotent dirty-range union, not a permanent “same payload means ignore” cache: two legitimate updates can invalidate the same interval. No event ordering or unique event ID is assumed. Late and duplicate deliveries may cause another harmless read.
4. Keep only the linked `healthUserId`, APNs token, an opaque installation credential, dirty ranges/revisions and minimal operational metadata. Never trust a caller-provided account ID without verifying account binding. A one-user deployment can provision that mapping administratively from verified `getIdentity` output; a multi-user service needs an authenticated binding flow.
5. APNs payload contains an opaque revision hint, no health values. The iPhone fetches pending ranges from the relay, reads Health API using its own OAuth token, commits local data/scores, then acknowledges the consumed revision. Later arrivals remain pending. Queue retention expiry forces full retained-window reconciliation.
6. Debounce bursts and send at most two silent pushes per hour per device, with one collapse key. This may delay some hints by design. Foreground querying still provides fast active use. Failure to deliver a push must not discard pending dirty ranges.

APNs background requests use `aps: {"content-available": 1}`, `apns-push-type: background`, `apns-priority: 5`. Apple may throttle, delay or discard them; delivery is not guaranteed and execution lasts at most 30 seconds. It advises no more than two or three/hour. Force-quit can prevent background launch. A relay cannot guarantee an up-to-date widget or run the phone's local scoring while iOS withholds execution. ([Background pushes](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app), [Apple DTS background limits](https://developer.apple.com/forums/thread/685525))

## Native authentication and widgets

Create an **iOS** OAuth client tied to the final bundle ID when implementation is authorized. Use Google's iOS sign-in SDK or an installed-app authorization-code flow through the system authentication session, with PKCE S256 and checked `state`. Use the iOS client's supported redirect; do not transplant Desktop loopback credentials. Installed apps cannot keep a client secret. Authorization is at `https://accounts.google.com/o/oauth2/v2/auth`; token exchange/refresh is at `https://oauth2.googleapis.com/token`. Store refresh credentials in Keychain with protection selected explicitly for needed background access, not in source control, shared widget JSON, logs or the relay. ([Native OAuth](https://developers.google.com/identity/protocols/oauth2/native-app))

External OAuth applications in Testing issue refresh tokens that expire after seven days for these health scopes. Publishing status is separate from public distribution and verification; changing it is a deliberate later configuration step, not a promise of immortal tokens. Handle consent revocation and reauthorization. ([OAuth token expiration](https://developers.google.com/identity/protocols/oauth2#expiration), [Health setup](https://developers.google.com/health/setup))

Widgets read an atomically published, minimal score snapshot from an App Group after successful local computation; they do not own a second ingestion engine. Request `WidgetCenter` timeline reload only when relevant committed data changes. Display per-score freshness/completeness. WidgetKit has dynamic budgets; Apple's typical frequently viewed widget budget is 40–70 reloads/day and reload timing varies. Timelines and newer WidgetKit push mechanisms are not continuous execution. ([Widget refresh](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/))

## Verification before promising freshness

Implementation must pass synthetic cases for repeated fetches, changed unnamed samples, moved sessions, deleted named records, out-of-order/duplicate hints, failed last pages, empty successful windows, rejected scopes, DST/travel, expired OAuth tokens, queue expiry and schema changes. Verify one input edit invalidates every dependent score revision.

Then measure on a real iPhone across ordinary wear, waking from sleep, workout completion, offline recovery, phone restart, Low Power Mode, disabled Background App Refresh and force-quit. Record device-sync time, latest metric observation, API check completion and local score completion separately. Compare like-for-like source families and date semantics with Google Health. Report observed median/tail catch-up latency and missing-data states; do not infer an SLA from a short trial. No real-account deletes or writes are needed to test ingestion semantics—use synthetic fixtures.

Remaining implementation checks: native OAuth redirect/refresh trial; actual `reconcile` response/schema parity with audited inputs; background credential accessibility; APNs entitlement/distribution prerequisites if relay chosen; and real measured end-to-end freshness. The public docs establish feasibility and limits, not that these paths have already been exercised in this project.
