import Foundation
import FitbitMetrics

/// Port of the audited Python adapter. It never invents observations or fills missing days.
public enum HealthNormalizer {
    public static let sourcePolicy = "google-wearables:reconcile:v1"

    public static func normalize(records: [HealthMetric: [JSONValue]], ageYears: Double,
                                 now: Date, timeZone: TimeZone, sleepTargetMinutes: Double = 480,
                                 completedWindows: [HealthMetric: [QueryWindow]] = [:]) throws -> InputBundle {
        guard ageYears.isFinite, (18...120).contains(ageYears) else { throw SyncError.invalidProfileAge }
        guard sleepTargetMinutes.isFinite, (360...720).contains(sleepTargetMinutes) else { throw SyncError.invalidSleepTarget }
        var work = Normalization(now: now, zone: timeZone)
        try work.heartRate(records[.heartRate] ?? [])
        try work.steps(records[.steps] ?? [], windows: completedWindows[.steps] ?? [])
        try work.daily(records[.heartRateVariability] ?? [], metric: .heartRateVariability)
        try work.daily(records[.restingHeartRate] ?? [], metric: .restingHeartRate)
        for metric in [HealthMetric.oxygenSaturation, .respiratoryRate, .skinTemperature] {
            try work.vital(records[metric] ?? [], metric: metric)
        }
        try work.sleep(records[.sleep] ?? [])
        let today = SyncDates.day(now, zone: timeZone)
        let days = work.days.keys.sorted().filter { $0 <= today }.map { key in
            var day = work.days[key]!
            day.heartRateBins = (work.bins[key] ?? [:]).sorted { $0.key < $1.key }.map { HeartRateBin(bpm: $0.key, seconds: $0.value) }
            day.issues.sort()
            return day
        }
        return InputBundle(generatedAt: SyncDates.iso(now), asOfDate: today, ageYears: ageYears,
                           sleepTargetMinutes: sleepTargetMinutes, days: days)
    }
}

private struct Normalization {
    let now: Date
    let zone: TimeZone
    var days: [String: DailyInput] = [:]
    var bins: [String: [Double: Double]] = [:]
    let calendar: Calendar
    private var cachedBounds: (start: Date, end: Date, key: String)?

    init(now: Date, zone: TimeZone) {
        self.now = now; self.zone = zone; self.calendar = SyncDates.calendar(zone)
    }

    mutating func bounds(_ date: Date) -> (Date, Date) {
        if let cachedBounds, cachedBounds.start <= date, date < cachedBounds.end {
            return (cachedBounds.start, cachedBounds.end)
        }
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        cachedBounds = (start, end, SyncDates.day(date, zone: zone))
        return (start, end)
    }
    @discardableResult mutating func day(_ stamp: Date) -> String {
        let (begin, end) = bounds(stamp)
        let key = cachedBounds!.key
        if days[key] == nil {
            days[key] = DailyInput(date: key, sourceKey: HealthNormalizer.sourcePolicy,
                dayDurationSeconds: end.timeIntervalSince(begin),
                elapsedSeconds: max(0, min(end, now).timeIntervalSince(begin)), isClosed: begin < calendar.startOfDay(for: now))
        }
        return key
    }
    mutating func flag(_ stamp: Date, _ issue: String) {
        let key = day(stamp)
        if !days[key]!.issues.contains(issue) { days[key]!.issues.append(issue) }
    }
    mutating func timestamp(_ value: JSONValue, offset: JSONValue) throws -> Date {
        let stamp = try SyncDates.instant(value)
        let supplied = offset.string.flatMap { $0.hasSuffix("s") ? Double($0.dropLast()) : nil }
        if supplied != Double(zone.secondsFromGMT(for: stamp)) { flag(stamp, "timezone_offset_mismatch") }
        if stamp > now { flag(stamp, "future_observation") }
        return stamp
    }
    func unique(_ points: [JSONValue], metric: HealthMetric) throws -> [JSONValue] {
        var seen: Set<JSONValue> = []
        return try points.compactMap { point in
            guard point.object != nil else { throw SyncError.malformedResponse }
            if !seen.insert(point).inserted { return nil }
            guard point["dataSource"] == .null || point["dataSource"] == .object([:]) else { throw SyncError.rawSource }
            guard let payload = point[metric.payloadKey].object else { throw SyncError.malformedResponse }
            return .object(payload)
        }
    }
    mutating func heartRate(_ points: [JSONValue]) throws {
        var samples: [Date: Double] = [:]
        var observed: Set<Date> = [], conflicts: Set<Date> = []
        for sample in try unique(points, metric: .heartRate) {
            let time = sample["sampleTime"]
            let stamp = try timestamp(time["physicalTime"], offset: time["utcOffset"])
            day(stamp)
            if stamp > now { continue }
            let previouslyObserved = observed.contains(stamp)
            observed.insert(stamp)
            guard let bpm = try? sample["beatsPerMinute"].numeric(25, 250) else {
                flag(stamp, "invalid_heart_rate"); conflicts.insert(stamp); samples.removeValue(forKey: stamp); continue
            }
            if previouslyObserved, samples[stamp] != bpm { flag(stamp, "conflicting_heart_rate"); conflicts.insert(stamp) }
            samples[stamp] = bpm
        }
        let ordered = observed.sorted()
        for (left, right) in zip(ordered, ordered.dropFirst()) {
            let duration = right.timeIntervalSince(left)
            guard !conflicts.contains(left), !conflicts.contains(right), duration > 0, duration <= 60, let bpm = samples[left] else { continue }
            var cursor = left
            while cursor < right {
                let key = day(cursor), stop = min(right, bounds(cursor).1)
                bins[key, default: [:]][bpm, default: 0] += stop.timeIntervalSince(cursor)
                cursor = stop
            }
        }
    }
    mutating func steps(_ points: [JSONValue], windows: [QueryWindow]) throws {
        var intervals: [String: [(Date, Date)]] = [:]
        var stamps: [String: Date] = [:]
        for sample in try unique(points, metric: .steps) {
            let interval = sample["interval"]
            let start = try timestamp(interval["startTime"], offset: interval["startUtcOffset"])
            let end = try timestamp(interval["endTime"], offset: interval["endUtcOffset"])
            let key = day(start)
            guard let count = try? sample["count"].numeric(0, 1_000_000), count.rounded() == count,
                  end > start, end.timeIntervalSince(start) <= 86400, end <= now, end <= bounds(start).1 else {
                flag(start, "invalid_steps"); continue
            }
            intervals[key, default: []].append((start, end)); stamps[key] = start
            days[key]!.steps = (days[key]!.steps ?? 0) + count
        }
        for (key, entries) in intervals {
            var lastEnd: Date?
            for (start, end) in entries.sorted(by: { $0.0 < $1.0 }) {
                if let lastEnd, start < lastEnd { flag(start, "overlapping_steps") }
                lastEnd = max(lastEnd ?? end, end)
            }
            let (start, end) = bounds(stamps[key]!)
            var reached = start
            for window in windows.sorted(by: { $0.start < $1.start }) where window.start <= reached && reached < window.end { reached = window.end }
            days[key]!.stepsComplete = reached >= end && !days[key]!.issues.contains { ["invalid_steps", "overlapping_steps", "timezone_offset_mismatch"].contains($0) }
        }
    }
    mutating func daily(_ points: [JSONValue], metric: HealthMetric) throws {
        let isHRV = metric == .heartRateVariability
        let field = isHRV ? "averageHeartRateVariabilityMilliseconds" : "beatsPerMinute"
        let name = isHRV ? "rmssdMs" : "restingHeartRate"
        for sample in try unique(points, metric: metric) {
            let stamp = try SyncDates.daily(sample["date"], zone: zone), key = day(stamp)
            guard let value = try? sample[field].numeric(isHRV ? 1 : 25, isHRV ? 200 : 250) else { flag(stamp, "invalid_" + name); continue }
            let old = isHRV ? days[key]!.rmssdMs : days[key]!.restingHeartRate
            var replacement: Double? = value
            if let old, old != value { flag(stamp, "conflicting_" + name); replacement = nil }
            if isHRV { days[key]!.rmssdMs = replacement }
            else {
                days[key]!.restingHeartRate = replacement
                let method = sample["dailyRestingHeartRateMetadata"]["calculationMethod"].string ?? "UNSPECIFIED"
                days[key]!.sourceKey = HealthNormalizer.sourcePolicy + "|rhr:" + method
            }
        }
    }
    mutating func vital(_ points: [JSONValue], metric: HealthMetric) throws {
        guard let field = metric.vitalField else { return }
        var rejected: Set<String> = []
        for sample in try unique(points, metric: metric) {
            let stamp = try SyncDates.daily(sample["date"], zone: zone), key = day(stamp)
            do {
                try SyncCache.validate(metric, point: .object([metric.payloadKey: sample]))
                let value = try sample[field.api].numeric(field.range.lowerBound, field.range.upperBound)
                if let prior = days[key]![keyPath: field.input], prior != value {
                    flag(stamp, "conflicting_" + field.name); rejected.insert(key)
                }
                days[key]![keyPath: field.input] = rejected.contains(key) ? nil : value
            } catch {
                flag(stamp, "invalid_" + field.name); rejected.insert(key)
                days[key]![keyPath: field.input] = nil
            }
        }
    }
    mutating func sleep(_ points: [JSONValue]) throws {
        for sample in try unique(points, metric: .sleep) {
            guard sample["metadata"]["processed"].bool == true, sample["metadata"]["mainSleep"].bool == true else { continue }
            let interval = sample["interval"]
            let start = try timestamp(interval["startTime"], offset: interval["startUtcOffset"])
            let end = try timestamp(interval["endTime"], offset: interval["endUtcOffset"]), key = day(end)
            guard end <= now else { continue }
            let summary = sample["summary"]
            guard let asleep = try? summary["minutesAsleep"].numeric(0, 1440),
                  let awake = try? summary["minutesAwake"].numeric(0, 1440),
                  let period = try? summary["minutesInSleepPeriod"].numeric(1, 1440),
                  asleep <= period, abs(asleep + awake - period) <= 1, end > start, end.timeIntervalSince(start) <= 86400 else {
                flag(end, "invalid_sleep"); continue
            }
            let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let parts = calendar.dateComponents([.hour, .minute, .second], from: midpoint)
            let minute = Double(parts.hour! * 60 + parts.minute!) + Double(parts.second!) / 60
            let stages: [String: Double]
            do { stages = try SyncCache.sleepStages(sample, asleepMinutes: asleep) }
            catch { flag(end, "invalid_sleep_stages"); stages = [:] }
            let normalized = SleepInput(asleepMinutes: asleep, periodMinutes: period, midpointMinute: minute,
                lightMinutes: stages["LIGHT"], deepMinutes: stages["DEEP"], remMinutes: stages["REM"],
                startTime: SyncDates.iso(start), endTime: SyncDates.iso(end))
            if days[key]!.issues.contains("multiple_main_sleeps") { continue }
            if let old = days[key]!.sleep, old.asleepMinutes != asleep || old.periodMinutes != period || old.midpointMinute != minute ||
                old.lightMinutes != normalized.lightMinutes || old.deepMinutes != normalized.deepMinutes || old.remMinutes != normalized.remMinutes ||
                old.startTime != normalized.startTime || old.endTime != normalized.endTime {
                flag(end, "multiple_main_sleeps"); days[key]!.sleep = nil
            } else { days[key]!.sleep = normalized }
        }
    }
}
