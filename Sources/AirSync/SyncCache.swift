import Foundation

struct SyncCache: Codable, Sendable {
    var version = 2
    var sourcePolicy = HealthNormalizer.sourcePolicy
    var ageYears: Double?
    var records: [HealthMetric: [JSONValue]] = [:]
    var completedWindows: [HealthMetric: [QueryWindow]] = [:]
    var checkedAt: Date?
    var lastSuccessfulSync: Date?
    var lastHistoricalRepair: Date?
    var lastRecentRepair: Date?
    // Attempts are separate from successes: a missing permission for one
    // metric must not make every healthy metric restart its full history.
    var lastHistoricalAttempt: Date?
    var lastRecentAttempt: Date?
    var lastDownloadAttempt: Date?
    var lastProfileCheck: Date?
    var failures: [MetricFailure] = []
    var revision = 0

    mutating func replace(_ metric: HealthMetric, window: QueryWindow, points: [JSONValue], at: Date, timeZone: TimeZone) throws {
        guard window.end > window.start else { throw SyncError.outOfWindow }
        var staged: [String: (event: Date, value: JSONValue)] = [:]
        var dailyPayloads: [Date: JSONValue] = [:]
        for point in points {
            let event = try Self.event(metric, point: point, timeZone: timeZone)
            try Self.validate(metric, point: point)
            guard window.contains(event) else { throw SyncError.outOfWindow }
            if metric.vitalField != nil {
                let payload = point[metric.payloadKey]
                if let prior = dailyPayloads[event], prior != payload { throw SyncError.conflictingRecords }
                dailyPayloads[event] = payload
            }
            let identity = try Self.identity(metric, point: point, timeZone: timeZone, event: event)
            if let prior = staged[identity], prior.value != point { throw SyncError.conflictingRecords }
            staged[identity] = (event, point)
        }
        let old = records[metric] ?? []
        var retained: [String: (event: Date, value: JSONValue)] = [:]
        for point in old {
            let event = try Self.event(metric, point: point, timeZone: timeZone)
            let identity = try Self.identity(metric, point: point, timeZone: timeZone, event: event)
            if !window.contains(event), staged[identity] == nil { retained[identity] = (event, point) }
        }
        retained.merge(staged) { _, new in new }
        var ordered: [(event: Date, key: String, value: JSONValue)] = []
        for (key, value) in retained { ordered.append((value.event, key, value.value)) }
        ordered.sort { left, right in left.event == right.event ? left.key < right.key : left.event < right.event }
        let replacement = ordered.map { $0.value }
        let windows = Self.union((completedWindows[metric] ?? []) + [window])
        if old != replacement || windows != completedWindows[metric] { revision += 1 }
        records[metric] = replacement
        completedWindows[metric] = windows
        failures.removeAll { $0.metric == metric.rawValue && $0.window.map { window.start <= $0.start && window.end >= $0.end } == true }
    }

    mutating func fail(metric: String, window: QueryWindow?, at: Date, error: any Error) {
        failures.removeAll { $0.metric == metric && $0.window == window }
        failures.append(MetricFailure(metric: metric, checkedAt: at, code: (error as? SyncError)?.code ?? "refresh_failed", window: window))
    }

    static func union(_ windows: [QueryWindow]) -> [QueryWindow] {
        var result: [QueryWindow] = []
        for window in windows.sorted(by: { $0.start < $1.start }) {
            if let prior = result.last, window.start <= prior.end {
                result[result.count - 1] = QueryWindow(start: prior.start, end: max(prior.end, window.end))
            } else { result.append(window) }
        }
        return result
    }

    static func event(_ metric: HealthMetric, point: JSONValue, timeZone: TimeZone) throws -> Date {
        let payload = point[metric.payloadKey]
        guard payload.object != nil else { throw SyncError.malformedResponse }
        if metric.isDaily { return try SyncDates.daily(payload["date"], zone: timeZone) }
        if metric == .heartRate { return try SyncDates.instant(payload["sampleTime"]["physicalTime"]) }
        return try SyncDates.instant(payload["interval"][metric == .sleep ? "endTime" : "startTime"])
    }

    static func identity(_ metric: HealthMetric, point: JSONValue, timeZone: TimeZone, event knownEvent: Date? = nil) throws -> String {
        if let named = point["dataPointName"].string ?? point["name"].string, !named.isEmpty { return "named:" + named }
        let event = try knownEvent ?? event(metric, point: point, timeZone: timeZone)
        return "event:\(event.timeIntervalSince1970)|end:\(point[metric.payloadKey]["interval"]["endTime"].string ?? "")"
    }

    static func validate(_ metric: HealthMetric, point: JSONValue) throws {
        guard point.object != nil, point[metric.payloadKey].object != nil else { throw SyncError.malformedResponse }
        guard point["dataSource"] == .null || point["dataSource"] == .object([:]) else { throw SyncError.rawSource }
        let payload = point[metric.payloadKey]
        if metric == .heartRate {
            try offset(payload["sampleTime"]["utcOffset"])
            _ = try payload["beatsPerMinute"].numeric(25, 250)
        } else if !metric.isDaily {
            let interval = payload["interval"]
            let duration = try SyncDates.instant(interval["endTime"]).timeIntervalSince(SyncDates.instant(interval["startTime"]))
            guard duration > 0, duration <= 86400 else { throw SyncError.invalidMeasurement }
            try offset(interval["startUtcOffset"]); try offset(interval["endUtcOffset"])
        }
        switch metric {
        case .steps:
            let value = try payload["count"].numeric(0, 1_000_000)
            guard value.rounded() == value else { throw SyncError.invalidMeasurement }
        case .restingHeartRate:
            _ = try payload["beatsPerMinute"].numeric(25, 250)
            let metadata = payload["dailyRestingHeartRateMetadata"]
            guard metadata == .null || (metadata.object != nil && (metadata["calculationMethod"] == .null || metadata["calculationMethod"].string != nil)) else { throw SyncError.malformedResponse }
        case .heartRateVariability:
            _ = try payload["averageHeartRateVariabilityMilliseconds"].numeric(1, 200)
            let fields = ["averageHeartRateVariabilityMilliseconds", "nonRemHeartRateBeatsPerMinute", "entropy", "deepSleepRootMeanSquareOfSuccessiveDifferencesMilliseconds"]
            guard fields.contains(where: { payload.object?[$0] != nil }) else { throw SyncError.invalidMeasurement }
            for field in fields where payload.object?[field] != nil { _ = try payload[field].numeric(0, 1_000_000) }
        case .oxygenSaturation, .respiratoryRate, .skinTemperature:
            let field = metric.vitalField!
            let value: Double
            do { value = try payload[field.api].numeric(field.range.lowerBound, field.range.upperBound) }
            catch {
                guard metric == .skinTemperature else { throw error }
                throw payload[field.api] == .null ? SyncError.missingNightlyTemperature : SyncError.invalidNightlyTemperature
            }
            if metric == .oxygenSaturation {
                let lower = try payload["lowerBoundPercentage"].numeric(0, 100)
                let upper = try payload["upperBoundPercentage"].numeric(0, 100)
                guard lower <= value, value <= upper else { throw SyncError.invalidMeasurement }
                if payload["standardDeviationPercentage"] != .null { _ = try payload["standardDeviationPercentage"].numeric(0, 100) }
            }
            // Only nightlyTemperatureCelsius feeds this app. Google's optional
            // baseline/variability fields may be unavailable during calibration;
            // they cannot invalidate the separately validated nightly reading.

        case .sleep:
            guard payload["metadata"] == .null || payload["metadata"].object != nil else { throw SyncError.malformedResponse }
            if payload["metadata"]["processed"].bool == true {
                let summary = payload["summary"]
                let asleep = try summary["minutesAsleep"].numeric(0, 1440), awake = try summary["minutesAwake"].numeric(0, 1440)
                let period = try summary["minutesInSleepPeriod"].numeric(1, 1440)
                guard asleep <= period, abs(asleep + awake - period) <= 1 else { throw SyncError.invalidMeasurement }
                // A stage breakdown is optional. Its own validation happens in
                // normalization; failure must not discard a valid sleep summary.
            }
        case .heartRate: break
        }
    }

    /// Only actual LIGHT/DEEP/REM summaries describe stages. Classic restlessness
    /// and unsuccessful stage derivations do not supply substitute stage values.
    static func sleepStages(_ payload: JSONValue, asleepMinutes: Double) throws -> [String: Double] {
        let status = payload["metadata"]["stagesStatus"]
        guard payload["type"].string != "CLASSIC",
              status == .null || status == .string("STAGES_STATE_UNSPECIFIED") || status == .string("SUCCEEDED") else { return [:] }
        let summary = payload["summary"]["stagesSummary"]
        if summary == .null { return [:] }
        guard let stages = summary.array else { throw SyncError.malformedResponse }
        var result: [String: Double] = [:]
        for stage in stages {
            guard let type = stage["type"].string else { throw SyncError.malformedResponse }
            guard ["LIGHT", "DEEP", "REM"].contains(type) else { continue }
            let minutes = try stage["minutes"].numeric(0, asleepMinutes)
            guard minutes.rounded() == minutes, result[type] == nil else { throw SyncError.invalidMeasurement }
            result[type] = minutes
        }
        let total = result.values.reduce(0, +)
        guard total <= asleepMinutes + 1, result.count < 3 || abs(total - asleepMinutes) <= 1 else { throw SyncError.invalidMeasurement }
        return result
    }

    static func offset(_ value: JSONValue) throws {
        guard let string = value.string,
              string.range(of: #"^-?\d+(?:\.\d+)?s$"#, options: .regularExpression) != nil,
              let number = Double(string.dropLast()), number.isFinite, abs(number) <= 86400 else { throw SyncError.invalidTimestamp }
    }

    func freshness(now: Date, timeZone: TimeZone) -> SyncFreshness {
        let latest = records.filter { !$0.key.isDaily }.flatMap { metric, points in
            points.compactMap { point -> Date? in
                // Interval end is the latest measurement for steps, although replacement uses start.
                let stamp = metric == .steps ? try? SyncDates.instant(point[metric.payloadKey]["interval"]["endTime"]) : try? Self.event(metric, point: point, timeZone: timeZone)
                return stamp.flatMap { $0 <= now ? $0 : nil }
            }
        }.max()
        return SyncFreshness(checkedAt: checkedAt, lastSuccessfulSync: lastSuccessfulSync,
            lastMeasurementAt: latest, failures: failures.sorted { $0.metric < $1.metric }, revision: revision,
            sourcePolicy: sourcePolicy, ageProvenance: "Current Google profile age in whole years; birth date unavailable")
    }

    static func read(from url: URL) throws -> SyncCache? {
        try checkURL(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var cache = try JSONDecoder().decode(SyncCache.self, from: Data(contentsOf: url))
        guard [1, 2].contains(cache.version), cache.sourcePolicy == HealthNormalizer.sourcePolicy else { throw SyncError.incompatibleCache }
        cache.version = 2
        return cache
    }

    func write(to url: URL) throws {
        try Self.checkURL(url)
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var mutableURL = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try mutableURL.setResourceValues(values)
    }

    static func checkURL(_ url: URL) throws {
        guard url.isFileURL else { throw SyncError.unsafeCache }
        for item in [url, url.deletingLastPathComponent()] {
            if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw SyncError.unsafeCache }
        }
    }
}
