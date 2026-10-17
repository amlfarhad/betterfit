import Foundation
import FitbitMetrics

/// Sendable JSON used only at the API/cache boundary. Raw payloads never enter the UI.
public enum JSONValue: Codable, Sendable, Hashable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([String: JSONValue].self) { self = .object(item) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> JSONValue { object?[key] ?? .null }
    var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    func numeric(_ lower: Double, _ upper: Double) throws -> Double {
        let value: Double?
        switch self { case .number(let n): value = n; case .string(let s): value = Double(s); default: value = nil }
        guard let value, value.isFinite, (lower...upper).contains(value) else { throw SyncError.invalidMeasurement }
        return value
    }
}

public enum HealthMetric: String, Codable, CaseIterable, Sendable {
    case steps, heartRate = "heart-rate", sleep
    case heartRateVariability = "daily-heart-rate-variability"
    case restingHeartRate = "daily-resting-heart-rate"
    case oxygenSaturation = "daily-oxygen-saturation"
    case respiratoryRate = "daily-respiratory-rate"
    case skinTemperature = "daily-sleep-temperature-derivations"

    var payloadKey: String {
        switch self {
        case .steps: "steps"
        case .heartRate: "heartRate"
        case .sleep: "sleep"
        case .heartRateVariability: "dailyHeartRateVariability"
        case .restingHeartRate: "dailyRestingHeartRate"
        case .oxygenSaturation: "dailyOxygenSaturation"
        case .respiratoryRate: "dailyRespiratoryRate"
        case .skinTemperature: "dailySleepTemperatureDerivations"
        }
    }
    var isDaily: Bool { ![.steps, .heartRate, .sleep].contains(self) }
    var filterField: String {
        switch self {
        case .steps: "steps.interval.start_time"
        case .heartRate: "heart_rate.sample_time.physical_time"
        case .sleep: "sleep.interval.end_time"
        case .heartRateVariability: "daily_heart_rate_variability.date"
        case .restingHeartRate: "daily_resting_heart_rate.date"
        case .oxygenSaturation: "daily_oxygen_saturation.date"
        case .respiratoryRate: "daily_respiratory_rate.date"
        case .skinTemperature: "daily_sleep_temperature_derivations.date"
        }
    }

    /// Native daily fields from the v4 DataPoint REST reference; no unit heuristics.
    var vitalField: (api: String, input: WritableKeyPath<DailyInput, Double?>, name: String, range: ClosedRange<Double>)? {
        switch self {
        case .oxygenSaturation: ("averagePercentage", \.oxygenSaturationPercent, "oxygenSaturationPercent", 0...100)
        case .respiratoryRate: ("breathsPerMinute", \.respiratoryRateBrpm, "respiratoryRateBrpm", Double.leastNonzeroMagnitude...Double.greatestFiniteMagnitude)
        case .skinTemperature: ("nightlyTemperatureCelsius", \.skinTemperatureCelsius, "skinTemperatureCelsius", -273.15...Double.greatestFiniteMagnitude)
        default: nil
        }
    }
}

public struct QueryWindow: Codable, Sendable, Hashable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    func contains(_ date: Date) -> Bool { start <= date && date < end }
}

public struct MetricFailure: Codable, Sendable, Equatable {
    public let metric: String
    public let checkedAt: Date
    public let code: String
    public let window: QueryWindow?
}

public struct SyncFreshness: Codable, Sendable {
    public let checkedAt: Date?
    public let lastSuccessfulSync: Date?
    /// Latest physical observation time across HR, steps and sleep, not device upload time.
    public let lastMeasurementAt: Date?
    public let failures: [MetricFailure]
    public let revision: Int
    public let sourcePolicy: String
    public let ageProvenance: String
}

public struct SyncSnapshot: Sendable {
    public let input: InputBundle
    public let scores: ScoreBundle
    public let freshness: SyncFreshness
}

public enum SyncError: Error, LocalizedError, Sendable, Equatable {
    case invalidMeasurement, malformedResponse, invalidTimestamp, rawSource, pagination, outOfWindow
    case conflictingRecords, invalidProfileAge, invalidSleepTarget, incompatibleCache, unsafeCache
    case http(Int), network, redirect, noCachedData
    case missingNightlyTemperature, invalidNightlyTemperature

    public var errorDescription: String? {
        switch self {
        case .invalidProfileAge: "Google profile age is missing or invalid. Update your profile age, then reconnect."
        case .invalidSleepTarget: "Sleep target must be between 360 and 720 minutes."
        case .http(401): "Google authorization expired. Reconnect your account."
        case .http(403): "Google Health access was denied. Reconnect with the required read permissions."
        case .http(429): "Google Health is limiting requests. Your saved data is preserved; try again later."
        case .http: "Google Health could not complete the request. Your saved data is preserved."
        case .network: "Could not reach Google Health. Your saved data is preserved."
        case .pagination: "Google Health returned incomplete pages. The previous window is preserved."
        case .rawSource: "Raw source data cannot be combined with the reconciled scoring stream."
        case .incompatibleCache: "The local cache uses an unsupported source policy or format. Disconnect before reconnecting."
        case .unsafeCache: "The private cache could not be safely opened."
        case .noCachedData: "Connect Google Health to download your measurements."
        case .redirect: "Google Health redirected a request. The request was stopped."
        default: "Google Health returned invalid measurements. The previous window is preserved."
        }
    }

    var code: String {
        switch self {
        case .http(let status): "http_\(status)"
        case .missingNightlyTemperature: "missing_nightly_temperature"
        case .invalidNightlyTemperature: "invalid_nightly_temperature"
        case .invalidMeasurement: "invalid_measurement"
        case .malformedResponse: "malformed_response"
        case .invalidTimestamp: "invalid_timestamp"
        case .outOfWindow: "out_of_window"
        case .conflictingRecords: "conflicting_records"
        case .rawSource: "raw_source"
        case .invalidProfileAge: "invalid_profile_age"
        case .pagination: "incomplete_pagination"
        case .network: "network_unavailable"
        case .redirect: "redirect_blocked"
        default: "invalid_response"
        }
    }
}

enum SyncDates {
    private static let instantPattern = try! NSRegularExpression(pattern: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})$"#)
    private static let utcCalendar = calendar(TimeZone(secondsFromGMT: 0)!)
    static func calendar(_ zone: TimeZone) -> Calendar {
        var result = Calendar(identifier: .gregorian); result.timeZone = zone; return result
    }
    static func day(_ date: Date, zone: TimeZone) -> String {
        let c = calendar(zone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func instant(_ value: JSONValue) throws -> Date {
        guard let string = value.string,
              instantPattern.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil else { throw SyncError.invalidTimestamp }
        let characters = Array(string.utf8)
        func integer(_ range: Range<Int>) -> Int { range.reduce(0) { $0 * 10 + Int(characters[$1] - 48) } }
        let year = integer(0..<4), month = integer(5..<7), day = integer(8..<10)
        let hour = integer(11..<13), minute = integer(14..<16), second = integer(17..<19)
        guard year >= 1, hour < 24, minute < 60, second < 60 else { throw SyncError.invalidTimestamp }
        var offset = 0
        if characters.last != 90 {
            let start = characters.count - 6
            let hours = integer((start + 1)..<(start + 3)), minutes = integer((start + 4)..<(start + 6))
            guard hours < 24, minutes < 60 else { throw SyncError.invalidTimestamp }
            offset = (hours * 3600 + minutes * 60) * (characters[start] == 45 ? -1 : 1)
        }
        let cal = utcCalendar
        let requested = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let local = cal.date(from: requested), cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: local) == requested else { throw SyncError.invalidTimestamp }
        var fraction = 0.0
        if characters[19] == 46 {
            var index = 20, divisor = 10.0
            // Python datetime truncates protobuf nanoseconds to microseconds.
            while index < characters.count && (48...57).contains(characters[index]) {
                if index < 26 { fraction += Double(characters[index] - 48) / divisor; divisor *= 10 }
                index += 1
            }
        }
        return local.addingTimeInterval(fraction - Double(offset))
    }
    static func daily(_ value: JSONValue, zone: TimeZone) throws -> Date {
        let year = try value["year"].numeric(1, 9999), month = try value["month"].numeric(1, 12), day = try value["day"].numeric(1, 31)
        guard year.rounded() == year, month.rounded() == month, day.rounded() == day else { throw SyncError.invalidTimestamp }
        let cal = calendar(zone)
        let components = DateComponents(year: Int(year), month: Int(month), day: Int(day))
        guard let result = cal.date(from: components), cal.dateComponents([.year, .month, .day], from: result) == components else { throw SyncError.invalidTimestamp }
        return result
    }
}
