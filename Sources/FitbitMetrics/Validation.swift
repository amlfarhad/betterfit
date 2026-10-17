import Foundation

/// Civil dates use a fixed Gregorian UTC calendar solely for date arithmetic.
/// Actual local day durations are supplied by the timezone-aware exporter.
struct CivilDate: Comparable {
    let instant: Date
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    init?(_ text: String) {
        guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] >= 1,
              let date = Self.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return nil }
        let checked = Self.calendar.dateComponents([.year, .month, .day], from: date)
        guard checked.year == parts[0], checked.month == parts[1], checked.day == parts[2] else { return nil }
        instant = date
    }
    private init(instant: Date) { self.instant = instant }
    func adding(days: Int) -> CivilDate {
        CivilDate(instant: Self.calendar.date(byAdding: .day, value: days, to: instant)!)
    }
    var text: String {
        let parts = Self.calendar.dateComponents([.year, .month, .day], from: instant)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.instant < rhs.instant }
}

enum InputValidator {
    static func validate(_ input: InputBundle) throws {
        func require(_ condition: Bool, _ code: String, _ path: String, _ message: String) throws {
            if !condition { throw InputValidationError(code, path, message) }
        }
        try require(input.schemaVersion == 1, "unsupportedSchema", "schemaVersion", "Expected schema version 1.")
        guard let asOf = CivilDate(input.asOfDate), input.asOfDate >= "0001-01-08" else {
            throw InputValidationError("invalidDate", "asOfDate", "Expected a valid YYYY-MM-DD date with seven representable preceding dates.")
        }
        try require(validTimestamp(input.generatedAt), "invalidTimestamp", "generatedAt", "Expected a valid ISO 8601 UTC timestamp ending in Z.")
        try require(input.ageYears.isFinite && (0...120).contains(input.ageYears), "invalidNumber", "ageYears", "Expected finite years in the general input range 0–120.")
        try require(input.sleepTargetMinutes.isFinite && input.sleepTargetMinutes > 0 && input.sleepTargetMinutes <= 1440,
                    "invalidNumber", "sleepTargetMinutes", "Expected a positive finite target no longer than 1440 minutes.")
        if let maximum = input.measuredMaxHeartRate {
            try require(maximum.isFinite && maximum > 0, "invalidNumber", "measuredMaxHeartRate", "Expected positive finite bpm.")
        }
        var seen: Set<String> = []
        for (index, day) in input.days.enumerated() {
            let path = "days[\(index)]"
            guard let date = CivilDate(day.date) else { throw InputValidationError("invalidDate", "\(path).date", "Expected a valid YYYY-MM-DD date.") }
            try require(seen.insert(day.date).inserted, "duplicateDate", "\(path).date", "Every local date must be unique.")
            try require(date <= asOf, "futureDate", "\(path).date", "A measurement date cannot follow asOfDate.")
            try require(!day.isClosed || date < asOf, "closedCurrentDate", "\(path).isClosed", "Closed dates must precede asOfDate.")
            try require(!day.sourceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "missingSource", "\(path).sourceKey", "An explicit source is required.")
            try require(day.dayDurationSeconds.isFinite && day.dayDurationSeconds > 0 && day.dayDurationSeconds <= 172800,
                        "invalidNumber", "\(path).dayDurationSeconds", "Expected a positive finite local-day duration no longer than 48 hours.")
            try require(day.elapsedSeconds.isFinite && day.elapsedSeconds >= 0 && day.elapsedSeconds <= day.dayDurationSeconds,
                        "invalidNumber", "\(path).elapsedSeconds", "Expected elapsed seconds in 0...dayDurationSeconds.")
            try require(!day.isClosed || abs(day.elapsedSeconds - day.dayDurationSeconds) <= 0.000001,
                        "incompleteClosedDay", "\(path).elapsedSeconds", "A closed day must have its full local-day duration elapsed.")
            if let steps = day.steps {
                try require(steps.isFinite && steps >= 0, "invalidNumber", "\(path).steps", "Expected nonnegative finite steps or null.")
            }
            for (name, value) in [("rmssdMs", day.rmssdMs), ("restingHeartRate", day.restingHeartRate)] {
                if let value {
                    try require(value.isFinite && value > 0, "invalidNumber", "\(path).\(name)", "Expected a positive finite value or null.")
                }
            }
            if let value = day.oxygenSaturationPercent {
                try require(value.isFinite && (0...100).contains(value), "invalidNumber", "\(path).oxygenSaturationPercent", "Expected a finite percentage in 0...100 or null.")
            }
            if let value = day.respiratoryRateBrpm {
                try require(value.isFinite && value > 0, "invalidNumber", "\(path).respiratoryRateBrpm", "Expected positive finite breaths per minute or null.")
            }
            if let value = day.skinTemperatureCelsius {
                try require(value.isFinite && value >= -273.15, "invalidNumber", "\(path).skinTemperatureCelsius", "Expected finite Celsius at or above absolute zero or null.")
            }
            var observedSeconds = 0.0
            for (binIndex, bin) in day.heartRateBins.enumerated() {
                let binPath = "\(path).heartRateBins[\(binIndex)]"
                try require(bin.bpm.isFinite && bin.bpm > 0, "invalidNumber", "\(binPath).bpm", "Expected positive finite bpm.")
                try require(bin.seconds.isFinite && bin.seconds >= 0, "invalidNumber", "\(binPath).seconds", "Expected nonnegative finite seconds.")
                observedSeconds += bin.seconds
            }
            try require(observedSeconds.isFinite && observedSeconds <= day.elapsedSeconds + 0.000001,
                        "excessHeartRateDuration", "\(path).heartRateBins", "Nonoverlapping observed intervals cannot exceed elapsed seconds.")
            if let sleep = day.sleep {
                try require(sleep.periodMinutes.isFinite && sleep.periodMinutes > 0 && sleep.periodMinutes <= 1440,
                            "invalidSleep", "\(path).sleep.periodMinutes", "Expected a positive finite period at most 1440 minutes.")
                try require(sleep.asleepMinutes.isFinite && sleep.asleepMinutes >= 0 && sleep.asleepMinutes <= sleep.periodMinutes,
                            "invalidSleep", "\(path).sleep.asleepMinutes", "Expected asleep minutes in 0...periodMinutes.")
                try require(sleep.midpointMinute.isFinite && sleep.midpointMinute >= 0 && sleep.midpointMinute < 1440,
                            "invalidSleep", "\(path).sleep.midpointMinute", "Expected local midpoint minute in [0,1440).")
                let stages = [("lightMinutes", sleep.lightMinutes), ("deepMinutes", sleep.deepMinutes), ("remMinutes", sleep.remMinutes)]
                for (name, value) in stages {
                    if let value {
                        try require(value.isFinite && value >= 0 && value <= sleep.asleepMinutes,
                                    "invalidSleep", "\(path).sleep.\(name)", "Expected finite stage minutes in 0...asleepMinutes or null.")
                    }
                }
                let observedStages = stages.compactMap(\.1)
                try require(observedStages.reduce(0, +) <= sleep.asleepMinutes + 1,
                            "invalidSleep", "\(path).sleep", "Observed sleep stages cannot exceed asleep minutes.")
                if observedStages.count == 3 {
                    try require(abs(observedStages.reduce(0, +) - sleep.asleepMinutes) <= 1,
                                "invalidSleep", "\(path).sleep", "Complete stages must sum to asleep minutes within rounding precision.")
                }
                for (name, value) in [("startTime", sleep.startTime), ("endTime", sleep.endTime)] {
                    if let value { try require(validTimestamp(value), "invalidTimestamp", "\(path).sleep.\(name)", "Expected a valid ISO 8601 UTC timestamp ending in Z.") }
                }
                if let start = sleep.startTime, let end = sleep.endTime {
                    guard let startDate = timestampDate(start), let endDate = timestampDate(end) else {
                        throw InputValidationError("invalidTimestamp", "\(path).sleep", "Expected representable sleep instants.")
                    }
                    let duration = endDate.timeIntervalSince(startDate)
                    try require(duration > 0 && duration <= 86400, "invalidSleep", "\(path).sleep", "Sleep instants must describe a positive interval no longer than 24 hours.")
                }
            }
        }
    }

    private static func validTimestamp(_ value: String) -> Bool {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$"#,
                          options: .regularExpression) != nil,
              CivilDate(String(value.prefix(10))) != nil else { return false }
        let time = value.dropFirst(11).prefix(8).split(separator: ":").compactMap { Int($0) }
        return time.count == 3 && time[0] < 24 && time[1] < 60 && time[2] < 60
    }

    private static func timestampDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
