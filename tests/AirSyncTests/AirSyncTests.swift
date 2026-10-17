import Foundation
import Testing
import FitbitMetrics
@testable import AirSync

private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
private let now = date("2026-09-29T12:00:00Z")
private let utc = TimeZone(secondsFromGMT: 0)!
private func json(_ string: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }
private func heart(_ stamp: String, _ bpm: Int = 100, offset: String = "0s") throws -> JSONValue {
    try json("{\"heartRate\":{\"sampleTime\":{\"physicalTime\":\"\(stamp)\",\"utcOffset\":\"\(offset)\"},\"beatsPerMinute\":\(bpm)}}")
}
private func steps(_ count: Int) throws -> JSONValue {
    try json("{\"name\":\"step-one\",\"steps\":{\"interval\":{\"startTime\":\"2026-09-29T11:00:00Z\",\"endTime\":\"2026-09-29T11:01:00Z\",\"startUtcOffset\":\"0s\",\"endUtcOffset\":\"0s\"},\"count\":\"\(count)\"}}")
}

@Test func normalizerIntegratesOnlyShortValidIntervalsAndSplitsMidnight() throws {
    let records: [HealthMetric: [JSONValue]] = [.heartRate: [
        try heart("2026-09-27T23:59:50Z"), try heart("2026-09-28T00:00:10Z"),
        try heart("2026-09-28T00:02:00Z")]]
    let input = try HealthNormalizer.normalize(records: records, ageYears: 40, now: now, timeZone: utc)
    #expect(input.days.count == 2)
    #expect(input.days.map { $0.heartRateBins.first?.seconds } == [10, 10])
    #expect(input.days.allSatisfy { $0.issues.isEmpty })
}

@Test func normalizerPreservesMissingStepsAndRequiresCompletedQueryCoverage() throws {
    let input = try HealthNormalizer.normalize(records: [.steps: [try steps(0)]], ageYears: 40, now: now, timeZone: utc,
        completedWindows: [.steps: [QueryWindow(start: date("2026-09-29T00:00:00Z"), end: date("2026-09-30T00:00:00Z"))]])
    #expect(input.days[0].steps == 0)
    #expect(input.days[0].stepsComplete)
    let missing = try HealthNormalizer.normalize(records: [.heartRate: [try heart("2026-09-29T11:00:00Z")]], ageYears: 40, now: now, timeZone: utc)
    #expect(missing.days[0].steps == nil)
    #expect(!missing.days[0].stepsComplete)
}

@Test func normalizerRejectsRawSourcesAndInvalidProfileAge() throws {
    let raw = try json("{\"dataSource\":{\"name\":\"raw\"},\"heartRate\":{}}")
    #expect(throws: SyncError.self) { try HealthNormalizer.normalize(records: [.heartRate: [raw]], ageYears: 40, now: now, timeZone: utc) }
    #expect(throws: SyncError.self) { try HealthNormalizer.normalize(records: [:], ageYears: .nan, now: now, timeZone: utc) }
}

@Test func normalizerFlagsConflictsAndTimezoneMismatch() throws {
    let input = try HealthNormalizer.normalize(records: [.heartRate: [try heart("2026-09-28T12:00:00Z"), try heart("2026-09-28T12:00:00Z", 110), try heart("2026-09-28T12:00:04Z", offset: "3600s")]], ageYears: 40, now: now, timeZone: utc)
    #expect(input.days[0].issues == ["conflicting_heart_rate", "timezone_offset_mismatch"])
    #expect(input.days[0].heartRateBins.isEmpty)
}

@Test func normalizerUsesSleepSummaryAndWakeDay() throws {
    let sleep = try json("{\"sleep\":{\"interval\":{\"startTime\":\"2026-09-27T23:00:00Z\",\"endTime\":\"2026-09-28T07:00:00Z\",\"startUtcOffset\":\"0s\",\"endUtcOffset\":\"0s\"},\"metadata\":{\"processed\":true,\"mainSleep\":true},\"summary\":{\"minutesAsleep\":420,\"minutesAwake\":60,\"minutesInSleepPeriod\":480}}}")
    let input = try HealthNormalizer.normalize(records: [.sleep: [sleep]], ageYears: 40, now: now, timeZone: utc)
    let wake = try #require(input.days.first { $0.date == "2026-09-28" })
    #expect(wake.sleep?.asleepMinutes == 420)
    #expect(wake.sleep?.midpointMinute == 180)
}

@Test func normalizerHonorsDSTDayLengthAndRHRMethodSource() throws {
    let daily = try json("{\"dailyRestingHeartRate\":{\"date\":{\"year\":2026,\"month\":3,\"day\":8},\"beatsPerMinute\":60,\"dailyRestingHeartRateMetadata\":{\"calculationMethod\":\"METHOD_A\"}}}")
    let input = try HealthNormalizer.normalize(records: [.restingHeartRate: [daily]], ageYears: 40, now: now, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
    #expect(input.days[0].dayDurationSeconds == 23 * 3600)
    #expect(input.days[0].sourceKey == "google-wearables:reconcile:v1|rhr:METHOD_A")
}

private actor FakeAPI {
    var calls: [URLRequest] = []
    var stepCount: Int? = 10
    var failingSteps = false
    var repeatedToken = false
    var age: Double? = 40
    func configure(count: Int?, failing: Bool = false, repeated: Bool = false) { stepCount = count; failingSteps = failing; repeatedToken = repeated }
    func setAge(_ value: Double?) { age = value }
    func call(_ request: URLRequest) throws -> HTTPResult {
        calls.append(request)
        if request.url!.path.hasSuffix("/profile") { return HTTPResult(data: try JSONEncoder().encode(JSONValue.object(["age": age.map(JSONValue.number) ?? .null])), status: 200) }
        if request.url!.path.contains("/steps/") {
            if failingSteps { return HTTPResult(data: Data(), status: 403) }
            let filter = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "filter" }!.value!
            let point = try steps(stepCount ?? 0)
            let bounds = filter.components(separatedBy: "\"")
            let event = date("2026-09-29T11:00:00Z")
            let start = try SyncDates.instant(.string(bounds[1])), end = try SyncDates.instant(.string(bounds[3]))
            let inWindow = start <= event && event < end
            let payload: JSONValue = .object(["dataPoints": .array(stepCount != nil && inWindow ? [point] : []), "nextPageToken": repeatedToken ? .string("again") : .null])
            return HTTPResult(data: try JSONEncoder().encode(payload), status: 200)
        }
        return HTTPResult(data: Data("{\"dataPoints\":[]}".utf8), status: 200)
    }
    func count() -> Int { calls.count }
    func requests() -> [URLRequest] { calls }
}

@Test func clientFollowsPagesAndRejectsRepeatedToken() async throws {
    let fake = FakeAPI()
    await fake.configure(count: nil, repeated: true)
    let client = HealthAPIClient(accessToken: { "synthetic" }, transport: { try await fake.call($0) }, sleep: { _ in })
    await #expect(throws: SyncError.self) { try await client.fetch(.steps, window: QueryWindow(start: date("2026-09-29T00:00:00Z"), end: date("2026-09-30T00:00:00Z")), timeZone: utc) }
    #expect(await fake.count() == 2)
    let calls = await fake.requests()
    #expect(calls.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "health.googleapis.com" })
    #expect(calls.allSatisfy { $0.url!.path.hasSuffix("dataPoints:reconcile") })
}

@Test func cacheReplacementIsIdempotentAndDeletesMissingRecords() throws {
    var cache = SyncCache()
    let window = QueryWindow(start: date("2026-09-29T00:00:00Z"), end: date("2026-09-30T00:00:00Z"))
    try cache.replace(.steps, window: window, points: [try steps(10)], at: now, timeZone: utc)
    let revision = cache.revision
    try cache.replace(.steps, window: window, points: [try steps(10)], at: now, timeZone: utc)
    #expect(cache.revision == revision)
    try cache.replace(.steps, window: window, points: [try steps(20)], at: now, timeZone: utc)
    #expect(cache.records[.steps]?.count == 1)
    #expect(cache.revision == revision + 1)
    try cache.replace(.steps, window: window, points: [], at: now, timeZone: utc)
    #expect(cache.records[.steps]?.isEmpty == true)
}

@Test func malformedReplacementPreservesPreviousGoodData() throws {
    var cache = SyncCache()
    let window = QueryWindow(start: date("2026-09-29T00:00:00Z"), end: date("2026-09-30T00:00:00Z"))
    let original = try steps(10)
    try cache.replace(.steps, window: window, points: [original], at: now, timeZone: utc)
    #expect(throws: SyncError.self) { try cache.replace(.steps, window: window, points: [json("{\"steps\":{}}")], at: now, timeZone: utc) }
    #expect(cache.records[.steps] == [original])
}

@Test func planUsesThirtyTwoLocalDaysThenSmallCatchupsAndRecentRepair() throws {
    var cache = SyncCache()
    let initial = SyncPlan.make(now: now, timeZone: utc, cache: cache, force: false)
    #expect(initial.kind == .historical)
    #expect(initial.windows.first?.start == date("2026-08-29T00:00:00Z"))
    #expect(initial.windows.last?.end == date("2026-09-30T00:00:00Z"))
    cache.lastHistoricalRepair = now; cache.lastRecentRepair = now; cache.lastSuccessfulSync = now
    let fast = SyncPlan.make(now: now.addingTimeInterval(60), timeZone: utc, cache: cache, force: false)
    #expect(fast.kind == .catchup)
    #expect(fast.windows[0].start == now.addingTimeInterval(60 - 7200))
    #expect(SyncPlan.make(now: now.addingTimeInterval(901), timeZone: utc, cache: cache, force: false).kind == .recent)
}

@Test func manualRefreshDoesNotForceMultiDayDownloadWhenHistoryIsCurrent() throws {
    var cache = SyncCache()
    cache.lastHistoricalRepair = now; cache.lastRecentRepair = now; cache.lastSuccessfulSync = now
    let plan = SyncPlan.make(now: now.addingTimeInterval(30), timeZone: utc, cache: cache, force: true)
    #expect(plan.kind == .catchup)
    #expect(plan.windows.count == 1)
    #expect(plan.windows[0].end.timeIntervalSince(plan.windows[0].start) == 7200)
}

@Test func partialInitialSyncDoesNotDownloadHealthyHistoryAgain() async throws {
    let fake = FakeAPI(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    await fake.configure(count: 10, failing: true)
    let sync = NativeHealthSync(cacheURL: folder.appendingPathComponent("cache.json"),
        client: HealthAPIClient(accessToken: { "synthetic" }, transport: { try await fake.call($0) }))
    _ = try await sync.refresh(now: now, timeZone: utc)
    let priorCount = await fake.count()
    _ = try await sync.refresh(now: now.addingTimeInterval(60), timeZone: utc, force: true)
    let recentRequests = Array(await fake.requests().dropFirst(priorCount))
    let heartRequests = recentRequests.filter { $0.url!.path.contains("/heart-rate/") }
    #expect(heartRequests.count == 1)
    let request = try #require(heartRequests.first)
    let filter = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "filter" }?.value)
    #expect(filter.contains("2026-09-29T10:01:00"))
}

@Test func dailyRetryWindowsAlignWithLocalDatesAfterTimezoneChange() throws {
    let zone = TimeZone(identifier: "America/Los_Angeles")!
    var cache = SyncCache()
    cache.fail(metric: HealthMetric.restingHeartRate.rawValue,
        window: QueryWindow(start: date("2026-08-29T00:00:00Z"), end: date("2026-09-05T00:00:00Z")),
        at: now, error: SyncError.network)
    let plan = SyncPlan(kind: .catchup, windows: [], dailyWindow: nil)
    let windows = plan.windows(for: .restingHeartRate, failures: cache.failures, timeZone: zone)
    let calendar = SyncDates.calendar(zone)
    #expect(!windows.isEmpty)
    #expect(windows.allSatisfy { calendar.startOfDay(for: $0.start) == $0.start && calendar.startOfDay(for: $0.end) == $0.end })
    #expect(windows.first?.start == date("2026-08-28T07:00:00Z"))
    #expect(windows.last?.end == date("2026-09-05T07:00:00Z"))
}

@Test func successfulSplitRetriesClearOnlyFullyCoveredFailures() async throws {
    let fake = FakeAPI(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("cache.json")
    var cache = SyncCache()
    cache.ageYears = 40; cache.lastProfileCheck = now
    cache.lastHistoricalRepair = now; cache.lastRecentRepair = now; cache.lastSuccessfulSync = now
    let failure = QueryWindow(start: now.addingTimeInterval(-7 * 86400 + 60), end: now.addingTimeInterval(60))
    let earlier = QueryWindow(start: now.addingTimeInterval(-8 * 86400), end: now.addingTimeInterval(-6 * 86400))
    cache.fail(metric: "steps", window: earlier, at: now, error: SyncError.network)
    cache.fail(metric: "steps", window: failure, at: now, error: SyncError.network)
    try cache.write(to: url)
    let sync = NativeHealthSync(cacheURL: url, client: HealthAPIClient(accessToken: { "synthetic" }, transport: { try await fake.call($0) }))
    let result = try await sync.refresh(now: now.addingTimeInterval(120), timeZone: utc, force: true)
    #expect(result.freshness.failures.isEmpty)
}

private actor ConcurrentAPI {
    var active = 0
    var maximum = 0
    func call(_ request: URLRequest) async throws -> HTTPResult {
        if request.url!.path.hasSuffix("/profile") {
            return HTTPResult(data: Data(#"{"age":40}"#.utf8), status: 200)
        }
        active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(20))
        return HTTPResult(data: Data(#"{"dataPoints":[]}"#.utf8), status: 200)
    }
    func peak() -> Int { maximum }
}

@Test func independentMetricsDownloadConcurrentlyWithBoundedFanout() async throws {
    let fake = ConcurrentAPI(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sync = NativeHealthSync(cacheURL: folder.appendingPathComponent("cache.json"),
        client: HealthAPIClient(accessToken: { "synthetic" }, transport: { try await fake.call($0) }))
    let snapshot = try await sync.refresh(now: now, timeZone: utc)
    #expect(snapshot.freshness.lastSuccessfulSync == now)
    #expect(await fake.peak() == 3)
}

@Test func refreshPersistsAndPreservesGoodDataOnPartialFailure() async throws {
    let fake = FakeAPI(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("cache.json")
    let sync = NativeHealthSync(cacheURL: url, client: HealthAPIClient(accessToken: { "synthetic" }, transport: { try await fake.call($0) }, sleep: { _ in }))
    let initial = try await sync.refresh(now: now, timeZone: utc)
    #expect(initial.input.days.first?.steps == 10)
    #expect(initial.freshness.lastMeasurementAt == date("2026-09-29T11:01:00Z"))
    #expect(initial.freshness.lastSuccessfulSync == now)
    let scoreEncoder = JSONEncoder(); scoreEncoder.outputFormatting = .sortedKeys
    #expect(try scoreEncoder.encode(initial.scores) == scoreEncoder.encode(MetricsEngine.evaluate(initial.input)))
    let count = await fake.count()
    _ = try await sync.refresh(now: now.addingTimeInterval(20), timeZone: utc)
    #expect(await fake.count() == count)
    await fake.configure(count: 20, failing: true)
    let partial = try await sync.refresh(now: now.addingTimeInterval(60), timeZone: utc, force: true)
    #expect(partial.input.days.first?.steps == 10)
    #expect(partial.freshness.failures.map(\.metric) == ["steps"])
    #expect(partial.freshness.checkedAt == now.addingTimeInterval(60))
    #expect(partial.freshness.lastSuccessfulSync == now)
    await fake.configure(count: 20)
    let corrected = try await sync.refresh(now: now.addingTimeInterval(120), timeZone: utc, force: true)
    #expect(corrected.input.days.first?.steps == 20)
    #expect(corrected.freshness.failures.isEmpty)
    let reopened = NativeHealthSync(cacheURL: url, accessToken: { "never-used" })
    let restored = try await reopened.load(now: now.addingTimeInterval(150), timeZone: utc, sleepTargetMinutes: 510)
    #expect(restored?.input.days.first?.steps == 20)
    #expect(restored?.input.sleepTargetMinutes == 510)
    await fake.configure(count: nil)
    let deleted = try await sync.refresh(now: now.addingTimeInterval(180), timeZone: utc, force: true)
    #expect(deleted.input.days.isEmpty)
    try await sync.clear()
    #expect(try await sync.load(now: now, timeZone: utc) == nil)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func concurrentRefreshesShareOneDownload() async throws {
    let fake = FakeAPI(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sync = NativeHealthSync(cacheURL: folder.appendingPathComponent("cache.json"), client: HealthAPIClient(accessToken: { "synthetic" }, transport: { request in
        try await Task.sleep(nanoseconds: 1_000_000)
        return try await fake.call(request)
    }, sleep: { _ in }))
    async let first = sync.refresh(now: now, timeZone: utc)
    async let second = sync.refresh(now: now, timeZone: utc)
    let (a, b) = try await (first, second)
    #expect(a.freshness.revision == b.freshness.revision)
    #expect(await fake.count() == 1 + HealthMetric.allCases.count * 5)
}

private actor Responses {
    var results: [HTTPResult]
    var attempts = 0
    var delays: [UInt64] = []
    init(_ results: [HTTPResult]) { self.results = results }
    func call(_ request: URLRequest) -> HTTPResult { attempts += 1; return results.count > 1 ? results.removeFirst() : results[0] }
    func pause(_ nanos: UInt64) { delays.append(nanos) }
    func counts() -> (Int, [UInt64]) { (attempts, delays) }
}

@Test func retryIsBoundedAndCapsRetryAfter() async throws {
    let fake = Responses([HTTPResult(data: Data(), status: 429, retryAfter: "999"), HTTPResult(data: Data(), status: 503), HTTPResult(data: Data(), status: 503), HTTPResult(data: Data(), status: 503)])
    let client = HealthAPIClient(accessToken: { "synthetic" }, transport: { await fake.call($0) }, sleep: { await fake.pause($0) })
    await #expect(throws: SyncError.http(503)) { try await client.profileAge() }
    let counts = await fake.counts()
    #expect(counts.0 == 4)
    #expect(counts.1 == [30_000_000_000, 2_000_000_000, 4_000_000_000])
}

@Test func redirectsAndMalformedCollectionsCannotReplaceGoodWindows() async throws {
    let redirected = HealthAPIClient(accessToken: { "synthetic" }, transport: { _ in HTTPResult(data: Data(), status: 302) }, sleep: { _ in })
    await #expect(throws: SyncError.redirect) { try await redirected.profileAge() }
    let malformed = HealthAPIClient(accessToken: { "synthetic" }, transport: { _ in HTTPResult(data: Data("{\"dataPoints\":null}".utf8), status: 200) }, sleep: { _ in })
    await #expect(throws: SyncError.malformedResponse) { try await malformed.fetch(.steps, window: QueryWindow(start: now, end: now.addingTimeInterval(60)), timeZone: utc) }
}

@Test func timestampsRejectNormalizedInvalidCalendarDates() throws {
    #expect(throws: SyncError.self) { try SyncDates.instant(.string("2026-02-30T12:00:00Z")) }
    #expect(throws: SyncError.self) { try SyncDates.instant(.string("2026-09-29T24:00:00Z")) }
}

@Test func cancellationDoesNotWritePartialCache() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("cache.json")
    let sync = NativeHealthSync(cacheURL: url, client: HealthAPIClient(accessToken: { "synthetic" }, transport: { _ in
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return HTTPResult(data: Data("{\"age\":40}".utf8), status: 200)
    }))
    let task = Task { try await sync.refresh(now: now, timeZone: utc) }
    try await Task.sleep(nanoseconds: 5_000_000)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

private actor MetricCancellationGate {
    var downloading = false
    func call(_ request: URLRequest) async throws -> HTTPResult {
        if request.url!.path.hasSuffix("/profile") { return HTTPResult(data: Data(#"{"age":40}"#.utf8), status: 200) }
        // The fifth metric starts only after an earlier result has been staged.
        if request.url!.path.contains("/daily-resting-heart-rate/") {
            downloading = true
            try await Task.sleep(for: .seconds(30))
        }
        return HTTPResult(data: Data(#"{"dataPoints":[]}"#.utf8), status: 200)
    }
    func started() -> Bool { downloading }
}

@Test(arguments: [true, false])
func cancellingAfterMetricStagingNeverCommitsPartialData(clear: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("cache.json"), gate = MetricCancellationGate()
    var cache = SyncCache()
    cache.ageYears = 40; cache.lastSuccessfulSync = now; cache.lastHistoricalRepair = now; cache.lastRecentRepair = now
    cache.records[.steps] = [try steps(10)]
    try cache.write(to: url)
    let original = try Data(contentsOf: url)
    let sync = NativeHealthSync(cacheURL: url,
        client: HealthAPIClient(accessToken: { "synthetic" }, transport: { try await gate.call($0) }))
    let task = Task { try await sync.refresh(now: now.addingTimeInterval(60), timeZone: utc, force: true) }
    while !(await gate.started()) { await Task.yield() }
    if clear { try await sync.clear() } else { task.cancel() }
    await #expect(throws: CancellationError.self) { try await task.value }
    if clear { #expect(!FileManager.default.fileExists(atPath: url.path)) }
    else { #expect(try Data(contentsOf: url) == original) }
}

@Test func unrelatedWindowSuccessDoesNotHidePriorFailures() throws {
    var cache = SyncCache()
    let first = QueryWindow(start: now.addingTimeInterval(-86400), end: now)
    let second = QueryWindow(start: now, end: now.addingTimeInterval(86400))
    cache.fail(metric: "steps", window: first, at: now, error: SyncError.network)
    try cache.replace(.steps, window: second, points: [], at: now, timeZone: utc)
    #expect(cache.failures.count == 1)
    try cache.replace(.steps, window: first, points: [], at: now, timeZone: utc)
    #expect(cache.failures.isEmpty)
}

@Test func timestampMatchesPythonMicrosecondPrecisionAndOffsetSemantics() throws {
    let expected = now.addingTimeInterval(0.999999)
    let actual = try SyncDates.instant(.string("2026-09-29T14:30:00.999999999+02:30"))
    #expect(abs(actual.timeIntervalSince(expected)) < 0.000001)
    #expect(try SyncDates.instant(.string("1970-01-01T00:00:00Z")).timeIntervalSince1970 == 0)
    #expect(try SyncDates.instant(.string("2000-02-29T23:59:59Z")) == date("2000-02-29T23:59:59Z"))
    #expect(throws: SyncError.self) { try SyncDates.instant(.string("1900-02-29T00:00:00Z")) }
    #expect(throws: SyncError.self) { try SyncDates.instant(.string("٢٠٢٦-09-29T12:00:00Z")) }
}

@Test func representativeHourlyHeartRateStreamKeepsFullCoverage() throws {
    let start = date("2026-09-29T10:00:00Z")
    let points: [JSONValue] = (0...900).map { index in
        .object(["heartRate": .object(["sampleTime": .object(["physicalTime": .string(SyncDates.iso(start.addingTimeInterval(Double(index * 4)))), "utcOffset": .string("0s")]), "beatsPerMinute": .number(100)])])
    }
    let input = try HealthNormalizer.normalize(records: [.heartRate: points], ageYears: 40, now: now, timeZone: utc)
    #expect(input.days[0].heartRateBins.first?.seconds == 3600)
}

@Test func outOfDomainReplacementPreservesPreviousGoodMeasurement() throws {
    var cache = SyncCache()
    let window = QueryWindow(start: date("2026-09-29T00:00:00Z"), end: date("2026-09-30T00:00:00Z"))
    let valid = try heart("2026-09-29T11:00:00Z", 100)
    try cache.replace(.heartRate, window: window, points: [valid], at: now, timeZone: utc)
    #expect(throws: SyncError.self) { try cache.replace(.heartRate, window: window, points: [heart("2026-09-29T11:00:00Z", 350)], at: now, timeZone: utc) }
    #expect(cache.records[.heartRate] == [valid])
    let malformedHRV = try json("{\"dailyHeartRateVariability\":{\"date\":{\"year\":2026,\"month\":9,\"day\":29},\"averageHeartRateVariabilityMilliseconds\":900}}")
    #expect(throws: SyncError.self) { try cache.replace(.heartRateVariability, window: window, points: [malformedHRV], at: now, timeZone: utc) }
}

@Test func refreshUsesCompletionTimeForMeasurementsArrivingDuringDownload() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let client = HealthAPIClient(accessToken: { "synthetic" }, transport: { request in
        if request.url!.path.hasSuffix("/profile") { return HTTPResult(data: Data("{\"age\":40}".utf8), status: 200) }
        let filter = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "filter" }!.value!
        let points: [JSONValue] = request.url!.path.contains("/heart-rate/") && filter.contains("2026-09-26") ? [try heart("2026-09-29T12:00:10Z")] : []
        return HTTPResult(data: try JSONEncoder().encode(JSONValue.object(["dataPoints": .array(points)])), status: 200)
    }, sleep: { _ in })
    let sync = NativeHealthSync(cacheURL: folder.appendingPathComponent("cache.json"), client: client, completionClock: { now.addingTimeInterval(15) })
    let snapshot = try await sync.refresh(now: now, timeZone: utc)
    #expect(snapshot.input.days.first?.issues.isEmpty == true)
    #expect(snapshot.freshness.checkedAt == now.addingTimeInterval(15))
    #expect(snapshot.freshness.lastMeasurementAt == now.addingTimeInterval(10))
}

@Test func missingProfileAgePreservesSavedInputAndReportsProfileFailure() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), fake = FakeAPI()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("cache.json")
    let sync = NativeHealthSync(cacheURL: url, client: HealthAPIClient(accessToken: { "synthetic" }, transport: { try await fake.call($0) }, sleep: { _ in }))
    _ = try await sync.refresh(now: now, timeZone: utc)
    await fake.setAge(nil)
    await #expect(throws: SyncError.invalidProfileAge) { try await sync.refresh(now: now.addingTimeInterval(60), timeZone: utc, force: true) }
    let saved = try await sync.load(now: now.addingTimeInterval(60), timeZone: utc)
    #expect(saved?.input.ageYears == 40)
    #expect(saved?.input.days.first?.steps == 10)
    #expect(saved?.freshness.failures.map(\.metric) == ["profile"])
    #expect(saved?.freshness.lastSuccessfulSync == now)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func namedCorrectionMovesAcrossWindowsWithoutResurrectingOldPosition() throws {
    var cache = SyncCache()
    let initial = try steps(10)
    let first = QueryWindow(start: date("2026-09-29T00:00:00Z"), end: date("2026-09-30T00:00:00Z"))
    let second = QueryWindow(start: date("2026-09-30T00:00:00Z"), end: date("2026-10-01T00:00:00Z"))
    try cache.replace(.steps, window: first, points: [initial], at: now, timeZone: utc)
    var point = initial.object!, payload = initial["steps"].object!, interval = initial["steps"]["interval"].object!
    interval["startTime"] = .string("2026-09-30T11:00:00Z"); interval["endTime"] = .string("2026-09-30T11:01:00Z")
    payload["interval"] = .object(interval); point["steps"] = .object(payload)
    let moved = JSONValue.object(point)
    try cache.replace(.steps, window: second, points: [moved], at: now, timeZone: utc)
    #expect(cache.records[.steps] == [moved])
    try cache.replace(.steps, window: first, points: [], at: now, timeZone: utc)
    #expect(cache.records[.steps] == [moved])
}

@Test func invalidThenValidDuplicateRetainsPythonConflictFlags() throws {
    let input = try HealthNormalizer.normalize(records: [.heartRate: [
        try heart("2026-09-29T11:00:00Z", 350), try heart("2026-09-29T11:00:00Z", 100),
        try heart("2026-09-29T11:00:04Z", 100)]], ageYears: 40, now: now, timeZone: utc)
    #expect(input.days[0].issues == ["conflicting_heart_rate", "invalid_heart_rate"])
    #expect(input.days[0].heartRateBins.isEmpty)
}

@Test func catchupWindowBoundsMatchSerializedAPIPrecision() throws {
    var cache = SyncCache()
    cache.lastHistoricalRepair = now; cache.lastRecentRepair = now; cache.lastSuccessfulSync = now
    let plan = SyncPlan.make(now: now.addingTimeInterval(60.0004), timeZone: utc, cache: cache, force: false)
    let window = plan.windows[0]
    #expect(try SyncDates.instant(.string(SyncDates.iso(window.start))) == window.start)
    #expect(try SyncDates.instant(.string(SyncDates.iso(window.end))) == window.end)
}
