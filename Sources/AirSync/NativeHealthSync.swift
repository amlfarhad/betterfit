import Foundation
import FitbitMetrics

struct SyncPlan: Sendable {
    enum Kind: Sendable { case historical, recent, catchup }
    let kind: Kind
    let windows: [QueryWindow]
    let dailyWindow: QueryWindow?

    static func make(now: Date, timeZone: TimeZone, cache: SyncCache, force: Bool) -> SyncPlan {
        let calendar = SyncDates.calendar(timeZone), today = SyncDates.calendar(timeZone).startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        let historical = (cache.lastHistoricalAttempt ?? cache.lastHistoricalRepair).map { now.timeIntervalSince($0) >= 7 * 86400 } ?? true
        let missed = (cache.lastDownloadAttempt ?? cache.lastSuccessfulSync).map { now.timeIntervalSince($0) > 2 * 86400 } ?? true
        // Manual refresh bypasses the caller's 60-second throttle, not the
        // repair schedule. Repeated pulls should only fetch recent changes.
        let recent = (cache.lastRecentAttempt ?? cache.lastRecentRepair).map { now.timeIntervalSince($0) >= 900 } ?? true
        if !historical && !missed && !recent {
            // Align replacement boundaries with the precision serialized into API predicates.
            let physicalEnd = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
            return SyncPlan(kind: .catchup, windows: [QueryWindow(start: physicalEnd.addingTimeInterval(-7200), end: physicalEnd)],
                            dailyWindow: QueryWindow(start: calendar.date(byAdding: .day, value: -1, to: today)!, end: end))
        }
        let days = historical || missed ? 32 : 3
        var start = calendar.date(byAdding: .day, value: 1 - days, to: today)!
        var windows: [QueryWindow] = []
        while start < end {
            let stop = min(end, calendar.date(byAdding: .day, value: 7, to: start)!)
            windows.append(QueryWindow(start: start, end: stop)); start = stop
        }
        return SyncPlan(kind: days == 32 ? .historical : .recent, windows: windows, dailyWindow: nil)
    }

    func windows(for metric: HealthMetric, failures: [MetricFailure], timeZone: TimeZone) -> [QueryWindow] {
        let current = metric.isDaily ? dailyWindow.map { [$0] } ?? windows : windows
        let calendar = SyncDates.calendar(timeZone)
        let pending = failures.filter { $0.metric == metric.rawValue }.compactMap(\.window).map { window in
            guard metric.isDaily else { return window }
            let start = calendar.startOfDay(for: window.start)
            let endDay = calendar.startOfDay(for: window.end)
            let end = endDay == window.end ? endDay : calendar.date(byAdding: .day, value: 1, to: endDay)!
            return QueryWindow(start: start, end: end)
        }
        // Include unresolved windows only for their affected metric, keeping
        // requests bounded to seven days and overlapping catchups coalesced.
        return SyncCache.union(current + pending).flatMap { window in
            var result: [QueryWindow] = [], start = window.start
            while start < window.end {
                let end = min(window.end, calendar.date(byAdding: .day, value: 7, to: start)!)
                result.append(QueryWindow(start: start, end: end)); start = end
            }
            return result
        }
    }
}

private struct DownloadedWindow: Sendable {
    let window: QueryWindow
    let receivedAt: Date
    let result: Result<[JSONValue], any Error>
}

private struct DownloadedMetric: Sendable {
    let metric: HealthMetric
    let windows: [DownloadedWindow]
}

/// One actor owns a private reconciled cache. The access-token provider owns refresh-token handling.
public actor NativeHealthSync {
    private let cacheURL: URL
    private let legacyCacheURL: URL?
    private let client: HealthAPIClient
    private let completionClock: (@Sendable () -> Date)?
    private var cache = SyncCache()
    private var loaded = false
    private var inFlight: (id: UUID, task: Task<SyncSnapshot, any Error>)?

    public init(cacheURL: URL, legacyCacheURL: URL? = nil, accessToken: @escaping @Sendable () async throws -> String) {
        self.cacheURL = cacheURL; self.legacyCacheURL = legacyCacheURL
        self.client = HealthAPIClient(accessToken: accessToken)
        self.completionClock = { Date() }
    }

    init(cacheURL: URL, legacyCacheURL: URL? = nil, client: HealthAPIClient, completionClock: (@Sendable () -> Date)? = nil) {
        self.cacheURL = cacheURL; self.legacyCacheURL = legacyCacheURL
        self.client = client; self.completionClock = completionClock
    }

    /// Concurrent callers share a single refresh. User cancellation cancels its network requests.
    public func refresh(now: Date = Date(), timeZone: TimeZone = .current,
                        sleepTargetMinutes: Double = 480, force: Bool = false) async throws -> SyncSnapshot {
        try Task.checkCancellation()
        if let inFlight { return try await inFlight.task.value }
        try ensureLoaded()
        if !force, let checked = cache.checkedAt, (0..<60).contains(now.timeIntervalSince(checked)), cache.ageYears != nil {
            return try snapshot(now: now, timeZone: timeZone, sleepTargetMinutes: sleepTargetMinutes)
        }
        let id = UUID()
        let task = Task { try await self.perform(now: now, timeZone: timeZone, sleepTargetMinutes: sleepTargetMinutes, force: force) }
        inFlight = (id, task)
        defer { if inFlight?.id == id { inFlight = nil } }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Re-normalizes the same raw cache for the current timezone, elapsed day and sleep target.
    public func load(now: Date = Date(), timeZone: TimeZone = .current,
                     sleepTargetMinutes: Double = 480) throws -> SyncSnapshot? {
        try ensureLoaded()
        guard cache.ageYears != nil else { return nil }
        return try snapshot(now: now, timeZone: timeZone, sleepTargetMinutes: sleepTargetMinutes)
    }

    public func clear() throws {
        inFlight?.task.cancel(); inFlight = nil
        let urls = [cacheURL] + (legacyCacheURL.map { [$0] } ?? [])
        // Validate both paths before deleting either. Rollback must not expose
        // the prior account after disconnect or an account transition.
        for url in urls { try SyncCache.checkURL(url) }
        for url in urls where FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        cache = SyncCache(); loaded = true
    }

    private func ensureLoaded() throws {
        guard !loaded else { return }
        if let legacyCacheURL, legacyCacheURL.standardizedFileURL == cacheURL.standardizedFileURL { throw SyncError.unsafeCache }
        // Never fall back after a corrupt/incompatible current cache. The old
        // build's enum cannot decode new metric names, so it is read-only here.
        if let current = try SyncCache.read(from: cacheURL) { cache = current }
        else if let legacyCacheURL { cache = try SyncCache.read(from: legacyCacheURL) ?? SyncCache() }
        else { cache = SyncCache() }
        loaded = true
    }

    private func snapshot(now: Date, timeZone: TimeZone, sleepTargetMinutes: Double) throws -> SyncSnapshot {
        guard let age = cache.ageYears else { throw SyncError.invalidProfileAge }
        let input = try HealthNormalizer.normalize(records: cache.records, ageYears: age, now: now, timeZone: timeZone,
                                                   sleepTargetMinutes: sleepTargetMinutes, completedWindows: cache.completedWindows)
        // Apply the shared engine's structural validation before data crosses the adapter boundary.
        let scores = try MetricsEngine.evaluate(input)
        return SyncSnapshot(input: input, scores: scores, freshness: cache.freshness(now: now, timeZone: timeZone))
    }

    private func perform(now: Date, timeZone: TimeZone, sleepTargetMinutes: Double, force: Bool) async throws -> SyncSnapshot {
        try Task.checkCancellation()
        guard sleepTargetMinutes.isFinite, (360...720).contains(sleepTargetMinutes) else { throw SyncError.invalidSleepTarget }
        let plan = SyncPlan.make(now: now, timeZone: timeZone, cache: cache, force: force)
        var staged = cache
        staged.checkedAt = now
        let profileDue = staged.ageYears == nil || force || (staged.lastProfileCheck.map { now.timeIntervalSince($0) >= 86400 } ?? true)
        if profileDue {
            do {
                let age = try await client.profileAge()
                if age != staged.ageYears { staged.ageYears = age; staged.revision += 1 }
                staged.lastProfileCheck = now
                staged.failures.removeAll { $0.metric == "profile" }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                let checked = max(now, completionClock?() ?? now)
                staged.checkedAt = checked
                staged.fail(metric: "profile", window: nil, at: checked, error: error)
                try staged.write(to: cacheURL); cache = staged
                throw error
            }
        }
        guard let age = staged.ageYears else { throw SyncError.invalidProfileAge }
        var failed = false
        let client = self.client, completionClock = self.completionClock, previousFailures = staged.failures
        let needsDailyHistory = Set(HealthMetric.allCases.filter { $0.vitalField != nil && staged.completedWindows[$0] == nil })
        let initialPlan = SyncPlan.make(now: now, timeZone: timeZone, cache: SyncCache(), force: false)
        // Different metrics are independent. Keep each metric's windows/pages
        // ordered, and limit concurrent requests to three to respect API quotas.
        try await withThrowingTaskGroup(of: DownloadedMetric.self) { group in
            var remaining = HealthMetric.allCases.makeIterator()
            func enqueue(_ metric: HealthMetric) {
                let metricPlan = needsDailyHistory.contains(metric) ? initialPlan : plan
                group.addTask {
                    let windows = metricPlan.windows(for: metric, failures: previousFailures, timeZone: timeZone)
                    var downloaded: [DownloadedWindow] = []
                    for window in windows {
                        try Task.checkCancellation()
                        let result: Result<[JSONValue], any Error>
                        do { result = .success(try await client.fetch(metric, window: window, timeZone: timeZone)) }
                        catch {
                            if error is CancellationError || Task.isCancelled { throw CancellationError() }
                            result = .failure(error)
                        }
                        downloaded.append(DownloadedWindow(window: window, receivedAt: max(now, completionClock?() ?? now), result: result))
                    }
                    return DownloadedMetric(metric: metric, windows: downloaded)
                }
            }
            for _ in 0..<3 { if let metric = remaining.next() { enqueue(metric) } }
            while let download = try await group.next() {
                try Task.checkCancellation()
                if let next = remaining.next() { enqueue(next) }
                let metric = download.metric
                var successfulWindows: [QueryWindow] = []
                for item in download.windows {
                    let window = item.window
                    do {
                        let points = try item.result.get()
                        // Validate every replacement before staging it. The
                        // committed cache remains untouched until all work ends.
                        var candidate = staged
                        try candidate.replace(metric, window: window, points: points, at: item.receivedAt, timeZone: timeZone)
                        let input = try HealthNormalizer.normalize(records: [metric: points], ageYears: age, now: item.receivedAt, timeZone: timeZone,
                            sleepTargetMinutes: sleepTargetMinutes, completedWindows: [metric: [window]])
                        guard !input.days.contains(where: { $0.issues.contains(where: { $0.hasPrefix("invalid_") && $0 != "invalid_sleep_stages" }) }) else { throw SyncError.invalidMeasurement }
                        _ = try MetricsEngine.evaluate(input)
                        staged = candidate
                        successfulWindows.append(window)
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        failed = true
                        staged.fail(metric: metric.rawValue, window: window, at: item.receivedAt, error: error)
                    }
                }
                // A retry can span several chunks. Only this run's successful
                // coverage may retire a failure spanning a chunk boundary.
                let repaired = SyncCache.union(successfulWindows)
                staged.failures.removeAll { failure in
                    guard failure.metric == metric.rawValue, let window = failure.window else { return false }
                    return repaired.contains { $0.start <= window.start && $0.end >= window.end }
                }
            }
        }
        let completedAt = max(now, completionClock?() ?? now)
        staged.checkedAt = completedAt
        staged.lastDownloadAttempt = completedAt
        if plan.kind == .historical { staged.lastHistoricalAttempt = completedAt }
        if plan.kind != .catchup { staged.lastRecentAttempt = completedAt }
        if !failed {
            staged.lastSuccessfulSync = completedAt
            if plan.kind == .historical { staged.lastHistoricalRepair = completedAt }
            if plan.kind != .catchup { staged.lastRecentRepair = completedAt }
        }
        try Task.checkCancellation()
        let finalInput = try HealthNormalizer.normalize(records: staged.records, ageYears: age, now: completedAt, timeZone: timeZone,
            sleepTargetMinutes: sleepTargetMinutes, completedWindows: staged.completedWindows)
        let scores = try MetricsEngine.evaluate(finalInput)
        try staged.write(to: cacheURL)
        cache = staged
        return SyncSnapshot(input: finalInput, scores: scores, freshness: staged.freshness(now: completedAt, timeZone: timeZone))
    }
}
