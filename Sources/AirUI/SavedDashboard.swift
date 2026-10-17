import Foundation
import FitbitMetrics

/// Small validated presentation input. The reconciled raw cache stays authoritative.
struct SavedDashboard: Codable {
    static let maximumBytes = 2_000_000
    static let maximumDays = 56
    var version = 1
    let input: InputBundle
    let timeZone: String
    let checkedAt: Date?
    let measuredAt: Date?
    let successfulAt: Date?

    init(input: InputBundle, timeZone: String, checkedAt: Date?, measuredAt: Date?, successfulAt: Date?) {
        var compact = input
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        if let end = formatter.date(from: input.asOfDate), let start = calendar.date(byAdding: .day, value: -(Self.maximumDays - 1), to: end) {
            let firstKey = formatter.string(from: start)
            compact.days = input.days.filter { $0.date >= firstKey && $0.date <= input.asOfDate }
        }
        self.input = compact; self.timeZone = timeZone
        self.checkedAt = checkedAt; self.measuredAt = measuredAt; self.successfulAt = successfulAt
    }

    static func restore(_ data: Data, timeZone: TimeZone, target: Double) throws -> (record: SavedDashboard, scores: ScoreBundle) {
        guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        let record = try JSONDecoder().decode(Self.self, from: data)
        guard record.version == 1, record.input.days.count <= Self.maximumDays, (360...720).contains(target), record.timeZone == timeZone.identifier,
              record.input.sleepTargetMinutes == target else { throw CocoaError(.coderReadCorrupt) }
        return (record, try MetricsEngine.evaluate(record.input))
    }
}
