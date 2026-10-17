import Foundation
import Testing
import FitbitMetrics
@testable import AirSync

private let signalNow = ISO8601DateFormatter().date(from: "2026-09-29T12:00:00Z")!
private let signalZone = TimeZone(secondsFromGMT: 0)!
private let signalWindow = QueryWindow(start: signalNow.addingTimeInterval(-12 * 3600), end: signalNow.addingTimeInterval(12 * 3600))
private func signalJSON(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
private func encoded<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
private func dailySignal(_ key: String, _ fields: [String: JSONValue]) -> JSONValue {
    .object([key: .object(fields.merging(["date": .object(["year": .number(2026), "month": .number(9), "day": .number(29)])]) { _, new in new })])
}
private func oxygen(_ value: Double) -> JSONValue {
    dailySignal("dailyOxygenSaturation", ["averagePercentage": .number(value), "lowerBoundPercentage": .number(value), "upperBoundPercentage": .number(value)])
}
private func stagedSleep(_ stages: String, status: String = "SUCCEEDED") throws -> JSONValue {
    try signalJSON("""
    {"sleep":{"type":"STAGES","interval":{"startTime":"2026-09-28T23:00:00Z","endTime":"2026-09-29T07:00:00Z","startUtcOffset":"0s","endUtcOffset":"0s"},"metadata":{"processed":true,"mainSleep":true,"stagesStatus":"\(status)"},"summary":{"minutesAsleep":"420","minutesAwake":"60","minutesInSleepPeriod":"480","stagesSummary":\(stages)}}}
    """)
}

@Test func betterFitUsesDocumentedDailyUnitsAndPreservesZero() throws {
    let oxygenMetric = try #require(HealthMetric(rawValue: "daily-oxygen-saturation"))
    let respiratoryMetric = try #require(HealthMetric(rawValue: "daily-respiratory-rate"))
    let temperatureMetric = try #require(HealthMetric(rawValue: "daily-sleep-temperature-derivations"))
    let input = try HealthNormalizer.normalize(records: [
        oxygenMetric: [oxygen(97.25)],
        respiratoryMetric: [dailySignal("dailyRespiratoryRate", ["breathsPerMinute": .number(15.6)])],
        temperatureMetric: [dailySignal("dailySleepTemperatureDerivations", ["nightlyTemperatureCelsius": .number(33.7), "baselineTemperatureCelsius": .number(33.5)])]
    ], ageYears: 40, now: signalNow, timeZone: signalZone)
    let day = try encoded(#require(input.days.first))
    #expect(day["oxygenSaturationPercent"] == .number(97.25))
    #expect(day["respiratoryRateBrpm"] == .number(15.6))
    #expect(day["skinTemperatureCelsius"] == .number(33.7))
    let zero = try HealthNormalizer.normalize(records: [oxygenMetric: [oxygen(0)]], ageYears: 40, now: signalNow, timeZone: signalZone)
    #expect(try encoded(zero.days[0])["oxygenSaturationPercent"] == .number(0))
    #expect(try encoded(zero.days[0])["respiratoryRateBrpm"] == .null)
}

@Test func betterFitReadsStageSummaryAndExplicitSleepTimes() throws {
    let sample = try stagedSleep(#"[{"type":"LIGHT","minutes":"260"},{"type":"DEEP","minutes":"90"},{"type":"REM","minutes":"70"},{"type":"AWAKE","minutes":"60"}]"#)
    let input = try HealthNormalizer.normalize(records: [.sleep: [sample]], ageYears: 40, now: signalNow, timeZone: signalZone)
    let sleep = try encoded(#require(input.days.first?.sleep))
    #expect(sleep["lightMinutes"] == .number(260))
    #expect(sleep["deepMinutes"] == .number(90))
    #expect(sleep["remMinutes"] == .number(70))
    #expect(try SyncDates.instant(sleep["startTime"]) == SyncDates.instant(.string("2026-09-28T23:00:00Z")))
    #expect(try SyncDates.instant(sleep["endTime"]) == SyncDates.instant(.string("2026-09-29T07:00:00Z")))
}

@Test func betterFitNeverRelabelsRestlessnessOrRejectedStages() throws {
    for sample in [try stagedSleep(#"[{"type":"ASLEEP","minutes":"420"},{"type":"RESTLESS","minutes":"60"}]"#),
                   try stagedSleep(#"[{"type":"REM","minutes":"70"}]"#, status: "REJECTED_COVERAGE")] {
        let input = try HealthNormalizer.normalize(records: [.sleep: [sample]], ageYears: 40, now: signalNow, timeZone: signalZone)
        let sleep = try encoded(#require(input.days.first?.sleep))
        #expect(sleep["lightMinutes"] == .null)
        #expect(sleep["deepMinutes"] == .null)
        #expect(sleep["remMinutes"] == .null)
    }
}

@Test func betterFitRejectsInvalidOptionalInputFields() throws {
    for fields in [#""oxygenSaturationPercent":101"#, #""respiratoryRateBrpm":-1"#, #""skinTemperatureCelsius":-274"#,
                   #""sleep":{"asleepMinutes":420,"periodMinutes":480,"midpointMinute":180,"lightMinutes":-1}"#,
                   #""sleep":{"asleepMinutes":420,"periodMinutes":480,"midpointMinute":180,"lightMinutes":300,"deepMinutes":90,"remMinutes":90}"#,
                   #""sleep":{"asleepMinutes":420,"periodMinutes":480,"midpointMinute":180,"endTime":"garbage"}"#] {
        let text = """
        {"schemaVersion":1,"generatedAt":"2026-09-29T12:00:00Z","asOfDate":"2026-09-29","ageYears":40,"days":[{"date":"2026-09-29","sourceKey":"synthetic","dayDurationSeconds":86400,"elapsedSeconds":43200,"isClosed":false,"stepsComplete":false,"heartRateBins":[],"issues":[],\(fields)}]}
        """
        let input = try JSONDecoder().decode(InputBundle.self, from: Data(text.utf8))
        #expect(throws: InputValidationError.self) { try MetricsEngine.evaluate(input) }
    }
}

@Test func betterFitInvalidDailyReplacementPreservesPriorValueAndSourceFence() throws {
    let metric = try #require(HealthMetric(rawValue: "daily-oxygen-saturation"))
    var cache = SyncCache()
    let prior = oxygen(98)
    try cache.replace(metric, window: signalWindow, points: [prior], at: signalNow, timeZone: signalZone)
    for point in [oxygen(101), dailySignal("dailyOxygenSaturation", ["averagePercentage": .number(97)]),
                  .object(["dataSource": .object(["name": .string("raw")]), "dailyOxygenSaturation": prior["dailyOxygenSaturation"]])] {
        #expect(throws: SyncError.self) { try cache.replace(metric, window: signalWindow, points: [point], at: signalNow, timeZone: signalZone) }
        #expect(cache.records[metric] == [prior])
    }
    try cache.replace(metric, window: signalWindow, points: [], at: signalNow, timeZone: signalZone)
    #expect(cache.records[metric] == [])
}

private func writeLegacyCache(to url: URL) throws -> Data {
    // Literal pre-upgrade v1 cache, including its alternating enum-key dictionary encoding.
    let data = Data(#"{"version":1,"sourcePolicy":"google-wearables:reconcile:v1","ageYears":40,"records":["daily-resting-heart-rate",[{"dailyRestingHeartRate":{"date":{"year":2026,"month":9,"day":29},"beatsPerMinute":"60"}}]],"completedWindows":[],"failures":[],"revision":7}"#.utf8)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return data
}

@Test func betterFitLegacyMigrationPreservesRollbackAndClearRemovesBothAccountsCaches() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let legacy = folder.appendingPathComponent("health-cache.json"), current = folder.appendingPathComponent("health-cache-v2.json")
    let original = try writeLegacyCache(to: legacy)
    let client = HealthAPIClient(accessToken: { "synthetic" }, transport: { request in
        HTTPResult(data: Data((request.url!.path.hasSuffix("/profile") ? #"{"age":40}"# : #"{"dataPoints":[]}"#).utf8), status: 200)
    })
    let sync = NativeHealthSync(cacheURL: current, legacyCacheURL: legacy, client: client)
    let restored = try await sync.load(now: signalNow, timeZone: signalZone)
    #expect(restored?.input.days.first?.restingHeartRate == 60)
    #expect(try Data(contentsOf: legacy) == original)
    _ = try await sync.refresh(now: signalNow, timeZone: signalZone, force: true)
    #expect(try SyncCache.read(from: current)?.version == 2)
    #expect(try Data(contentsOf: legacy) == original)
    // The newer empty cache must win over the legacy account history.
    let reopened = NativeHealthSync(cacheURL: current, legacyCacheURL: legacy, accessToken: { "unused" })
    #expect(try await reopened.load(now: signalNow, timeZone: signalZone)?.input.days.isEmpty == true)
    try await reopened.clear()
    #expect(!FileManager.default.fileExists(atPath: current.path))
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(try await NativeHealthSync(cacheURL: current, legacyCacheURL: legacy, accessToken: { "unused" }).load(now: signalNow, timeZone: signalZone) == nil)
}

@Test func betterFitExistingInvalidCacheNeverFallsBackToLegacy() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let legacy = folder.appendingPathComponent("health-cache.json"), current = folder.appendingPathComponent("health-cache-v2.json")
    _ = try writeLegacyCache(to: legacy)
    try Data("invalid".utf8).write(to: current)
    let sync = NativeHealthSync(cacheURL: current, legacyCacheURL: legacy, accessToken: { "unused" })
    await #expect(throws: (any Error).self) { try await sync.load(now: signalNow, timeZone: signalZone) }
}

private actor SignalRequests {
    var requests: [URLRequest] = []
    func call(_ request: URLRequest) -> HTTPResult {
        requests.append(request)
        return HTTPResult(data: Data((request.url!.path.hasSuffix("/profile") ? #"{"age":40}"# : #"{"dataPoints":[]}"#).utf8), status: 200)
    }
    func all() -> [URLRequest] { requests }
}

@Test func betterFitNewDailyStreamsBackfillWithoutRestartingExistingHealthyHistory() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("health-cache-v2.json")
    var cache = SyncCache()
    cache.ageYears = 40; cache.lastProfileCheck = signalNow; cache.lastSuccessfulSync = signalNow
    cache.lastHistoricalRepair = signalNow; cache.lastRecentRepair = signalNow
    try cache.write(to: url)
    let requests = SignalRequests()
    let sync = NativeHealthSync(cacheURL: url, client: HealthAPIClient(accessToken: { "synthetic" }, transport: { await requests.call($0) }))
    _ = try await sync.refresh(now: signalNow.addingTimeInterval(60), timeZone: signalZone)
    let calls = await requests.all()
    #expect(calls.filter { $0.url!.path.contains("/heart-rate/") }.count == 1)
    for (type, filterField) in [("daily-oxygen-saturation", "daily_oxygen_saturation.date"), ("daily-respiratory-rate", "daily_respiratory_rate.date"), ("daily-sleep-temperature-derivations", "daily_sleep_temperature_derivations.date")] {
        let dailyCalls = calls.filter { $0.url!.path.contains("/\(type)/") }
        #expect(dailyCalls.count == 5)
        let first = try #require(dailyCalls.first?.url)
        let items = try #require(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.contains(URLQueryItem(name: "dataSourceFamily", value: "users/me/dataSourceFamilies/google-wearables")))
        #expect(items.first { $0.name == "filter" }?.value == "\(filterField) >= \"2026-08-29\" AND \(filterField) < \"2026-09-05\"")
    }
}

@Test func betterFitDifferentNamesCannotHideConflictingDailySummaries() throws {
    var cache = SyncCache()
    let original = oxygen(98)
    try cache.replace(.oxygenSaturation, window: signalWindow, points: [original], at: signalNow, timeZone: signalZone)
    let points = [98.0, 97.0].enumerated().map { index, value in
        JSONValue.object(["name": .string("synthetic-\(index)"), "dailyOxygenSaturation": oxygen(value)["dailyOxygenSaturation"]])
    }
    #expect(throws: SyncError.conflictingRecords) { try cache.replace(.oxygenSaturation, window: signalWindow, points: points, at: signalNow, timeZone: signalZone) }
    #expect(cache.records[.oxygenSaturation] == [original])
}

@Test func betterFitOptionalFieldsDecodeOldInputAndDoNotChangeScoreFormulas() throws {
    let original = InputBundle(generatedAt: "2026-09-29T12:00:00Z", asOfDate: "2026-09-29", ageYears: 40, days: [
        DailyInput(date: "2026-09-29", sourceKey: "synthetic", dayDurationSeconds: 86400, elapsedSeconds: 43200, isClosed: false,
                   heartRateBins: [HeartRateBin(bpm: 140, seconds: 600)], rmssdMs: 40, restingHeartRate: 60,
                   sleep: SleepInput(asleepMinutes: 420, periodMinutes: 480, midpointMinute: 180))
    ])
    let old = try JSONDecoder().decode(InputBundle.self, from: JSONEncoder().encode(original))
    #expect(old.days[0].oxygenSaturationPercent == nil)
    #expect(old.days[0].sleep?.endTime == nil)
    var expanded = old
    expanded.days[0].oxygenSaturationPercent = 97
    expanded.days[0].respiratoryRateBrpm = 16
    expanded.days[0].skinTemperatureCelsius = 33.7
    expanded.days[0].sleep?.lightMinutes = 260
    expanded.days[0].sleep?.deepMinutes = 90
    expanded.days[0].sleep?.remMinutes = 70
    expanded.days[0].sleep?.startTime = "2026-09-28T23:00:00Z"
    expanded.days[0].sleep?.endTime = "2026-09-29T07:00:00Z"
    let roundTrip = try JSONDecoder().decode(InputBundle.self, from: JSONEncoder().encode(expanded))
    #expect(try encoded(roundTrip) == encoded(expanded))
    #expect(try encoded(MetricsEngine.evaluate(original)) == encoded(MetricsEngine.evaluate(roundTrip)))
}

@Test func betterFitStageZeroAndAbsentValuesRemainDistinctWhileBadStagesStayHidden() throws {
    let valid = try stagedSleep(#"[{"type":"LIGHT","minutes":"420"},{"type":"DEEP","minutes":"0"}]"#)
    var cache = SyncCache()
    try cache.replace(.sleep, window: signalWindow, points: [valid], at: signalNow, timeZone: signalZone)
    let input = try HealthNormalizer.normalize(records: [.sleep: [valid]], ageYears: 40, now: signalNow, timeZone: signalZone)
    #expect(input.days[0].sleep?.deepMinutes == 0)
    #expect(input.days[0].sleep?.remMinutes == nil)
    for stages in [#"[{"type":"REM","minutes":"-1"}]"#, #"[{"type":"LIGHT","minutes":"300"},{"type":"DEEP","minutes":"90"},{"type":"REM","minutes":"90"}]"#,
                   #"[{"type":"LIGHT","minutes":"200"},{"type":"LIGHT","minutes":"220"}]"#] {
        let point = try stagedSleep(stages)
        #expect(throws: SyncError.self) { try SyncCache.sleepStages(point["sleep"], asleepMinutes: 420) }
        try cache.replace(.sleep, window: signalWindow, points: [point], at: signalNow, timeZone: signalZone)
        let normalized = try HealthNormalizer.normalize(records: cache.records, ageYears: 40, now: signalNow, timeZone: signalZone)
        #expect(normalized.days.first?.sleep?.asleepMinutes == 420)
        #expect(normalized.days.first?.sleep?.lightMinutes == nil)
        #expect(normalized.days.first?.sleep?.deepMinutes == nil)
        #expect(normalized.days.first?.sleep?.remMinutes == nil)
    }
}

@Test func betterFitConflictingOrInvalidVitalsStayMissingRegardlessOfRecordOrder() throws {
    let samples = [oxygen(97), oxygen(98), oxygen(96)]
    for points in [samples, Array(samples.reversed()), [oxygen(101), oxygen(98)]] {
        let result = try HealthNormalizer.normalize(records: [.oxygenSaturation: points], ageYears: 40, now: signalNow, timeZone: signalZone)
        #expect(result.days[0].oxygenSaturationPercent == nil)
        #expect(result.days[0].issues.contains { $0.hasSuffix("oxygenSaturationPercent") })
    }
    for (metric, point) in [(HealthMetric.respiratoryRate, dailySignal("dailyRespiratoryRate", ["breathsPerMinute": .number(.infinity)])),
                            (.skinTemperature, dailySignal("dailySleepTemperatureDerivations", ["nightlyTemperatureCelsius": .number(.nan)]))] {
        #expect(throws: SyncError.self) { try SyncCache.validate(metric, point: point) }
    }
}

@Test func betterFitDailyFailureRetainsGoodDataAndRetriesOnlyThatSignalHistory() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("health-cache-v2.json")
    let requests = SignalRequests()
    var cache = SyncCache()
    cache.ageYears = 40; cache.lastProfileCheck = signalNow; cache.lastSuccessfulSync = signalNow
    cache.lastHistoricalRepair = signalNow; cache.lastRecentRepair = signalNow
    let failedWindow = QueryWindow(start: signalWindow.start.addingTimeInterval(-7 * 86400), end: signalWindow.start)
    try cache.replace(.oxygenSaturation, window: signalWindow, points: [oxygen(98)], at: signalNow, timeZone: signalZone)
    cache.fail(metric: HealthMetric.oxygenSaturation.rawValue, window: failedWindow, at: signalNow, error: SyncError.http(403))
    for metric in [HealthMetric.respiratoryRate, .skinTemperature] { cache.completedWindows[metric] = [signalWindow] }
    try cache.write(to: url)
    let client = HealthAPIClient(accessToken: { "synthetic" }, transport: { request in
        _ = await requests.call(request)
        if request.url!.path.contains("/daily-oxygen-saturation/") { return HTTPResult(data: Data(), status: 403) }
        return HTTPResult(data: Data(#"{"dataPoints":[]}"#.utf8), status: 200)
    })
    let result = try await NativeHealthSync(cacheURL: url, client: client).refresh(now: signalNow.addingTimeInterval(60), timeZone: signalZone)
    #expect(result.input.days.first?.oxygenSaturationPercent == 98)
    #expect(result.input.days.first?.issues.isEmpty == true)
    #expect(result.freshness.failures.allSatisfy { $0.metric == "daily-oxygen-saturation" })
    #expect(result.freshness.lastSuccessfulSync == signalNow)
    let calls = await requests.all()
    #expect(calls.filter { $0.url!.path.contains("/daily-oxygen-saturation/") }.count == 2)
    #expect(calls.filter { $0.url!.path.contains("/daily-respiratory-rate/") }.count == 1)
}

private func completeSignalHistory(issue: String? = nil) -> InputBundle {
    let days = (21...28).map { day in
        DailyInput(date: "2026-09-\(day)", sourceKey: "synthetic", dayDurationSeconds: 86400, elapsedSeconds: 86400, isClosed: true,
                   steps: 8000, stepsComplete: true, heartRateBins: [HeartRateBin(bpm: 100, seconds: 86400)], rmssdMs: 40, restingHeartRate: 60,
                   sleep: SleepInput(asleepMinutes: 480, periodMinutes: 510, midpointMinute: 180), issues: issue.map { [$0] } ?? [])
    }
    return InputBundle(generatedAt: "2026-09-29T12:00:00Z", asOfDate: "2026-09-29", ageYears: 40, days: days)
}

@Test func betterFitOptionalVitalFlagsDoNotBlockUnrelatedLegacyScoresOrAgeCollection() throws {
    let baseline = try MetricsEngine.evaluate(completeSignalHistory())
    for name in ["oxygenSaturationPercent", "respiratoryRateBrpm", "skinTemperatureCelsius"] {
        for prefix in ["invalid_", "conflicting_"] {
            let result = try MetricsEngine.evaluate(completeSignalHistory(issue: prefix + name))
            #expect(try encoded(result.days) == encoded(baseline.days))
            #expect(try encoded(result.biologicalAge) == encoded(baseline.biologicalAge))
            #expect(result.diagnostics.contains { $0.code == "inputIssue" && $0.message == prefix + name })
        }
    }
}

@Test func betterFitSleepStageQualityDoesNotBlockMovementButUnknownFlagsStillFailClosed() throws {
    let baseline = try MetricsEngine.evaluate(completeSignalHistory())
    let stages = try MetricsEngine.evaluate(completeSignalHistory(issue: "invalid_sleep_stages"))
    #expect(try encoded(stages.days.map(\.strain)) == encoded(baseline.days.map(\.strain)))
    #expect(try encoded(stages.biologicalAge) == encoded(baseline.biologicalAge))
    #expect(try encoded(stages.days) == encoded(baseline.days))
    let unknown = try MetricsEngine.evaluate(completeSignalHistory(issue: "unrecognized_quality_issue"))
    #expect(unknown.days.allSatisfy { $0.sleep.status == .unavailable && $0.sleepRegularity.status == .unavailable && $0.recovery.status == .unavailable && $0.strain.status == .unavailable })
    #expect(unknown.biologicalAge.collection.eligibleDays == 0)
}

@Test func inconsistentOptionalStagesDoNotDiscardValidSleepSummary() throws {
    for stages in [#"[{"type":"LIGHT","minutes":"300"},{"type":"DEEP","minutes":"90"},{"type":"REM","minutes":"90"}]"#,
                   #"[{"type":"LIGHT","minutes":"-1"}]"#,
                   #"[{"type":"LIGHT","minutes":"300"},{"type":"LIGHT","minutes":"120"}]"#] {
        let point = try stagedSleep(stages)
        var cache = SyncCache()
        try cache.replace(.sleep, window: signalWindow, points: [point], at: signalNow, timeZone: signalZone)
        let input = try HealthNormalizer.normalize(records: cache.records, ageYears: 40, now: signalNow, timeZone: signalZone)
        let day = try #require(input.days.first)
        #expect(day.sleep?.asleepMinutes == 420)
        #expect(day.sleep?.periodMinutes == 480)
        #expect(day.sleep?.lightMinutes == nil && day.sleep?.deepMinutes == nil && day.sleep?.remMinutes == nil)
        #expect(day.issues.contains("invalid_sleep_stages"))
        #expect(try MetricsEngine.evaluate(input).days.first?.sleep.value != nil)
    }
}

@Test func genuinelyInvalidSleepSummaryIsStillRejected() throws {
    let point = try signalJSON("""
    {"sleep":{"type":"STAGES","interval":{"startTime":"2026-09-28T23:00:00Z","endTime":"2026-09-29T07:00:00Z","startUtcOffset":"0s","endUtcOffset":"0s"},"metadata":{"processed":true,"mainSleep":true},"summary":{"minutesAsleep":"520","minutesAwake":"60","minutesInSleepPeriod":"480"}}}
    """)
    #expect(throws: SyncError.self) { try SyncCache.validate(.sleep, point: point) }
    let input = try HealthNormalizer.normalize(records: [.sleep: [point]], ageYears: 40, now: signalNow, timeZone: signalZone)
    #expect(input.days.first?.sleep == nil)
    #expect(try MetricsEngine.evaluate(input).days.first?.sleep.value == nil)
}

@Test func refreshCommitsValidSleepSummaryWhenOptionalStagesFail() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("health-cache-v2.json")
    var cache = SyncCache()
    cache.ageYears = 40; cache.lastProfileCheck = signalNow
    cache.lastSuccessfulSync = signalNow; cache.lastHistoricalRepair = signalNow
    try cache.write(to: url)
    let point = try stagedSleep(#"[{"type":"LIGHT","minutes":"300"},{"type":"DEEP","minutes":"90"},{"type":"REM","minutes":"90"}]"#)
    let response = try JSONEncoder().encode(JSONValue.object(["dataPoints": .array([point])]))
    let client = HealthAPIClient(accessToken: { "synthetic" }, transport: { request in
        HTTPResult(data: request.url!.path.contains("/sleep/") ? response : Data(#"{"dataPoints":[]}"#.utf8), status: 200)
    })
    let sync = NativeHealthSync(cacheURL: url, client: client)
    let snapshot = try await sync.refresh(now: signalNow, timeZone: signalZone)
    #expect(snapshot.freshness.failures.isEmpty)
    #expect(snapshot.input.days.first?.sleep?.asleepMinutes == 420)
    #expect(snapshot.scores.days.first?.sleep.value != nil)
    #expect(snapshot.input.days.first?.sleep?.lightMinutes == nil)
    let reopened = NativeHealthSync(cacheURL: url, accessToken: { "unused" })
    #expect(try await reopened.load(now: signalNow, timeZone: signalZone)?.scores.days.first?.sleep.value != nil)
}

@Test func unusedTemperatureBaselineCannotInvalidateNightlyReading() throws {
    let point = dailySignal("dailySleepTemperatureDerivations", [
        "nightlyTemperatureCelsius": .number(33.7),
        "baselineTemperatureCelsius": .string("NaN"),
        "relativeNightlyStddev30dCelsius": .string("NaN")])
    var cache = SyncCache()
    try cache.replace(.skinTemperature, window: signalWindow, points: [point], at: signalNow, timeZone: signalZone)
    let input = try HealthNormalizer.normalize(records: cache.records, ageYears: 40, now: signalNow, timeZone: signalZone)
    #expect(input.days.first?.skinTemperatureCelsius == 33.7)
    #expect(input.days.first?.issues.isEmpty == true)
    let invalid = dailySignal("dailySleepTemperatureDerivations", ["nightlyTemperatureCelsius": .string("NaN")])
    #expect(throws: SyncError.invalidNightlyTemperature) { try SyncCache.validate(.skinTemperature, point: invalid) }
    let missing = dailySignal("dailySleepTemperatureDerivations", [:])
    #expect(throws: SyncError.missingNightlyTemperature) { try SyncCache.validate(.skinTemperature, point: missing) }
}
