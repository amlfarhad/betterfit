import Foundation

enum WidgetMetric: String, CaseIterable, Sendable {
    case recovery, activity, sleep

    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .recovery: "heart.fill"
        case .activity: "figure.walk"
        case .sleep: "moon.fill"
        }
    }
    // Preserve the installed URL scheme and legacy metric route across the rename.
    var deepLink: URL { URL(string: "form://metric/\(self == .activity ? "strain" : rawValue)")! }
}

enum WidgetMetricState: Sendable {
    case ready, missing, calibrating, provisional, partial, live, stale

    var label: String {
        switch self {
        case .ready: "Score"
        case .missing: "No data"
        case .calibrating: "Calibrating"
        case .provisional: "Early baseline"
        case .partial: "Partial data"
        case .live: "So far today"
        case .stale: "Saved reading"
        }
    }
    var shortLabel: String {
        switch self {
        case .ready: "/ 100"
        case .missing: "NO DATA"
        case .calibrating: "LEARNING"
        case .provisional: "EARLY"
        case .partial: "PARTIAL"
        case .live: "TODAY"
        case .stale: "SAVED"
        }
    }
}

/// A deliberately tiny cache contract. The widget cannot authenticate or fetch.
struct WidgetSnapshot: Decodable, Sendable {
    enum Mode: String, Decodable, Sendable { case connected, imported, demo }

    let generatedAt: Date
    let measuredAt: Date?
    let date: String
    let mode: Mode?
    var recovery: Double?
    let recoveryStatus: String
    var strain: Double?
    let strainStatus: String
    var sleep: Double?
    let sleepStatus: String
    var age: Double?
    let ageStatus: String
    let ageCollectedDays: Int
    // Optional additions keep existing saved snapshots readable. Missing is never zero.
    var activityMinutes: Double? = nil
    var activityBaselineMinutes: Double? = nil
    var activityCoverage: Double? = nil

    static let empty = WidgetSnapshot(
        generatedAt: .distantPast, measuredAt: nil, date: "", mode: nil,
        recovery: nil, recoveryStatus: "Open BetterFit", strain: nil, strainStatus: "Open BetterFit",
        sleep: nil, sleepStatus: "Open BetterFit", age: nil, ageStatus: "Open BetterFit", ageCollectedDays: 0
    )

    static func decode(_ data: Data) throws -> WidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid snapshot timestamp")
            }
            return date
        }
        var value = try decoder.decode(Self.self, from: data)
        // Display provenance requires a known mode and a real measurement day.
        let formatter = dayFormatter()
        guard value.mode != nil, let day = formatter.date(from: value.date), formatter.string(from: day) == value.date else {
            throw SnapshotError.invalidProvenance
        }
        value.recovery = finite(value.recovery, in: 0...100)
        value.strain = finite(value.strain, in: 0...21)
        value.sleep = finite(value.sleep, in: 0...100)
        value.age = finite(value.age, in: 0...150)
        value.activityMinutes = finite(value.activityMinutes, in: 0...1440)
        value.activityCoverage = finite(value.activityCoverage, in: 0...1)
        value.activityBaselineMinutes = finite(value.activityBaselineMinutes, in: Double.leastNonzeroMagnitude...1440)
        return value
    }

    func value(for metric: WidgetMetric) -> Double? {
        switch metric {
        case .recovery: recovery
        case .activity: activityMinutes
        case .sleep: sleep
        }
    }

    func progress(for metric: WidgetMetric) -> Double? {
        guard let value = value(for: metric) else { return nil }
        if metric == .activity {
            guard let reference = activityBaselineMinutes,
                  let coverage = activityCoverage, coverage >= 0.8,
                  strainStatus != "partial", strainStatus != "insufficientCoverage" else { return nil }
            return min(value / reference, 1)
        }
        return value / 100
    }

    /// Six hours is a freshness indication, not a promise that WidgetKit will refresh.
    /// Day identity uses the device calendar so yesterday's measurement is always marked.
    func isStale(at now: Date, calendar: Calendar = .current) -> Bool {
        guard mode != nil, mode != .demo else { return false }
        let formatter = Self.dayFormatter()
        formatter.timeZone = calendar.timeZone
        guard formatter.string(from: now) == date else { return true }
        let saveAge = now.timeIntervalSince(generatedAt)
        if saveAge > 6 * 3600 || saveAge < -300 { return true }
        if let measuredAt {
            let measurementAge = now.timeIntervalSince(measuredAt)
            if measurementAge > 6 * 3600 || measurementAge < -300 { return true }
        }
        return false
    }

    func state(for metric: WidgetMetric, at now: Date, calendar: Calendar = .current) -> WidgetMetricState {
        guard mode != nil else { return .missing }
        let status: String
        switch metric {
        case .recovery: status = recoveryStatus
        case .activity: status = strainStatus
        case .sleep: status = sleepStatus
        }
        guard value(for: metric) != nil else {
            return ["calibrating", "collecting"].contains(status) ? .calibrating : .missing
        }
        if isStale(at: now, calendar: calendar) { return .stale }
        if status == "partial" || status == "insufficientCoverage" ||
            (metric == .activity && (activityCoverage == nil || activityCoverage! < 0.8)) { return .partial }
        if status == "provisional" { return .provisional }
        if status == "live" { return .live }
        return .ready
    }

    func provenanceLabel(at now: Date, calendar: Calendar = .current) -> String {
        switch mode {
        case .demo: return "Sample data"
        case .imported: return "Imported · \(measurementLabel)"
        case nil: return "Open BetterFit"
        case .connected: return "\(isStale(at: now, calendar: calendar) ? "Saved" : "Fitbit") · \(measurementLabel)"
        }
    }

    var sourceLabel: String {
        switch mode {
        case .connected: "FITBIT"
        case .imported: "IMPORTED"
        case .demo: "SAMPLE DATA"
        case nil: "OPEN BETTERFIT"
        }
    }

    var measurementLabel: String {
        let formatter = Self.dayFormatter()
        guard let value = formatter.date(from: date) else { return "—" }
        formatter.dateFormat = "MMM d"
        return formatter.string(from: value)
    }

    private static func finite(_ value: Double?, in range: ClosedRange<Double>) -> Double? {
        guard let value, value.isFinite, range.contains(value) else { return nil }
        return value
    }

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    private enum SnapshotError: Error { case invalidProvenance }
}
