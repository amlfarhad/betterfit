# Form — native iPhone app design

User approved dark and refined graphite/ivory with lime Recovery, ice-blue Strain and violet Sleep. Form is a working product name. Build is authorized; continue without additional aesthetic approval gates. Native SwiftUI, local verified FitbitMetrics calculations, no LLM or hosted inference.

## Visual direction

Bevel's clear metric hierarchy and WHOOP's athletic data density inform an original interface. Dark graphite base #0D1012; lifted #181D20 surfaces with top-edge highlights and subtle radial light; warm ivory #F2F0E9; secondary #9DA5A7. Semantic accents: lime #D6F58B, ice blue #8DCBEC, lavender #B7A5EE. No full-screen purple wash, default List/Form screens, uniform body typography or unstyled system rows.

Typography: Avenir Next regular/medium/demi headings and labels, light large numerical display, tracked 10–11pt metadata, compact tabular numbers, clear 13/15/20/34/70+ scale. Dynamic Type scales actual text, with adaptive layouts for large sizes. Continuous rounded panels, 24pt page gutters, 12pt related gaps, 28–36pt section rhythm. Use depth to show containment. Hairline dividers and small glyphs serve information; no decorative icon tile grids.

Motion: spring selection and sheet transitions; a single controlled gauge entrance; change-specific numeric transitions. No repeating ornamental animation. Respect Reduce Motion. Press scale/haptics confirm deliberate interaction.

## Screens

Today: date rail with history selection, connection/freshness entry, Recovery hero or honest baseline state, compact Sleep and Strain cards, signal row (HRV/RHR/sleep duration), Biological Age collection/estimate feature, recent daily load plot. Pull-to-refresh and explicit retry; no fabricated scores or narrative AI feed.

Metric detail: selected date, large score, chart with gaps for missing values, numeric contributors, concise formula explanation and collection/coverage reason. Sleep regularity separate. Daily selection flows into score detail.

Trends: 7/28-day control, metric selection, true daily history, available-sample average, coverage and raw HRV/RHR/steps. Do not interpolate missing observations or imply a calibration line is a health score.

Biological Age: movement-estimate qualifier adjacent to title; numeric result only when engine permits; otherwise designed seven-day collection visualization. Show exact eligibility reasons, age/step inputs, model method and limitations, source link. A separate historical week can only use its own as-of engine evaluation.

Connection sheet: source and freshness, Google sign-in/reauthorization, import private canonical JSON, sleep target adjustment, disconnect, local-data provenance. Initial onboarding provides connect and optional explicitly labeled synthetic demo. No network required to explore demo. Import and demo are separate data modes and never pretend to be live.

Widgets: small daily score and medium three-score glance, App Group snapshot, measurement/check date and calibration dashes. No background API in widget; app writes snapshot and reloads timelines. Time-driven freshness caption remains honest.

## Architecture

Existing FitbitMetrics remains unchanged. Add AirSync (Foundation API/cache/normalization), AirAuth (PKCE/system-browser/Keychain), AirUI (shared SwiftUI views and view model), AirPreview (macOS native visual QA host). The iPhone @main app and WidgetKit extension live under iOS/. An Xcode project references local Swift package products. macOS preview reuses actual views; it is not an iOS simulator or substitute for final on-phone tests.

iOS sign-in needs its own client ID/reversed scheme, supplied through local build configuration. Do not reuse Desktop tokens or embed private snapshots in app resources. Default standalone install starts disconnected; explicit import supports current account data. Keychain holds tokens; Application Support stores private cache, protected on iOS. No public uploads or extra permissions.

Refresh on foreground/manual, no overlapping tasks, visible poll eligibility 60 seconds, recent corrections and bounded historical repair. Google upload and iOS scheduling constraints stay visible. BGAppRefresh schedules best-effort opportunities, never guarantees intervals. Recompute with the exact local native engine after successful data changes; preserve last good content on network failure.

## Verification

Test normalization and auth security boundaries with synthetic inputs, compare native normalization to the verified Python output on a private snapshot without logging values. Build SwiftUI on macOS; render actual views at 393px and compact width, inspect visual hierarchy/cropping; exercise navigation, history, detail, import, theme continuity and calibration. Compile/validate Xcode project structure; full iOS build/simulator/device requires full Xcode, absent on this host at start. Clearly report unverified device-only behavior.
