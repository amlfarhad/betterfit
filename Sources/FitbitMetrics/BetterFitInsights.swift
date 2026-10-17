import Foundation

/// Descriptive comparisons, never medical classifications or readiness advice.
public enum InsightComparison: String, Codable, Sendable {
    case belowUsual, withinUsual, aboveUsual, buildingBaseline, accumulating, unavailable

    public var label: String {
        switch self {
        case .belowUsual: "Below your usual range"
        case .withinUsual: "Within your usual range"
        case .aboveUsual: "Above your usual range"
        case .buildingBaseline: "Building your baseline"
        case .accumulating: "Accumulating so far"
        case .unavailable: "No comparison available"
        }
    }
}

/// The median and linearly interpolated 10th–90th percentiles of valid prior
/// observations. This empirical app convention is not a clinical normal range.
public struct PersonalBaseline: Codable, Sendable {
    public let median: Double
    public let lower: Double
    public let upper: Double
    public let sampleCount: Int
    public let windowDays: Int
}

public struct ActivityInsight: Codable, Sendable {
    public let observedMinutes: Double?
    public let coverageFraction: Double?
    /// Index 0: below 50% max HR. Indices 1...5: 50–60, 60–70, 70–80,
    /// 80–90 and >=90%. Empty means no trustworthy observed intervals.
    public let zoneMinutes: [Double]
    public let elevatedMinutes: Double?
    public let higherIntensityMinutes: Double?
    public let maxHeartRate: Double
    public let maximumIsEstimated: Bool
    public let legacyStrain: Double?
    /// The prior complete-day range of elevatedMinutes, in minutes.
    public let baseline: PersonalBaseline?
    public let comparison: InsightComparison
    public let headline: String
    public let detail: String
}

public struct SleepInsight: Codable, Sendable {
    public let asleepMinutes: Double?
    public let periodMinutes: Double?
    public let targetMinutes: Double
    public let efficiencyPercent: Double?
    /// Sum of positive shortfalls against the chosen target for complete known
    /// nights in seven calendar dates ending on the selected date. No imputation.
    public let deficitMinutes: Double?
    public let knownNights: Int
    public let windowNights: Int
    public let midpointDeviationMinutes: Double?
    public let priorNights: Int
    public let lightMinutes: Double?
    public let deepMinutes: Double?
    public let remMinutes: Double?
    public let startTime: String?
    public let endTime: String?
    public let headline: String
    public let detail: String
}

public enum VitalKind: String, CaseIterable, Codable, Sendable {
    case hrv, restingHeartRate, oxygenSaturation, respiratoryRate, skinTemperature

    public var title: String {
        switch self {
        case .hrv: "Heart rate variability"
        case .restingHeartRate: "Resting heart rate"
        case .oxygenSaturation: "Blood oxygen"
        case .respiratoryRate: "Breathing rate"
        case .skinTemperature: "Skin temperature"
        }
    }

    public var unit: String {
        switch self {
        case .hrv: "ms"
        case .restingHeartRate: "bpm"
        case .oxygenSaturation: "%"
        case .respiratoryRate: "br/min"
        case .skinTemperature: "°C"
        }
    }
}

public struct VitalInsight: Codable, Sendable, Identifiable {
    public var id: VitalKind { kind }
    public let kind: VitalKind
    public let value: Double?
    public let unit: String
    public let baseline: PersonalBaseline?
    /// Selected observation minus the prior median, in the displayed unit.
    /// Oxygen changes are percentage points; temperature is a skin measurement.
    public let deviation: Double?
    public let comparison: InsightComparison
    public let headline: String
}

public struct DailyInsight: Codable, Sendable {
    public let date: String
    public let sourceKey: String
    public let isClosed: Bool
    public let activity: ActivityInsight
    public let sleep: SleepInsight
    public let vitals: [VitalInsight]
}

/// A pure presentation layer over validated canonical data and its matching
/// scores. Uses the selected local date and generatedAt, never the system clock.
/// Evaluate on input/date changes; do not recompute from a SwiftUI body.
public enum BetterFitInsights {
    public static let modelVersion = "betterfit-insights-1.0.0"

    public static func evaluate(input: InputBundle, scores: ScoreBundle, date: String) -> DailyInsight? {
        guard let selectedDate = CivilDate(date), date <= input.asOfDate,
              input.sleepTargetMinutes.isFinite, (0...1440).contains(input.sleepTargetMinutes),
              input.sleepTargetMinutes > 0 else { return nil }
        let selected = input.days.filter { $0.date == date }
        guard selected.count == 1, let day = selected.first else { return nil }
        let maximum = input.measuredMaxHeartRate ?? 208 - 0.7 * input.ageYears
        guard maximum.isFinite, maximum > 0 else { return nil }
        let lower = selectedDate.adding(days: -28).text
        // Duplicate dates cannot count twice even if an unvalidated caller slips
        // through. Normal engine evaluation rejects duplicates before this layer.
        let grouped = Dictionary(grouping: input.days, by: \.date)
        let prior = input.days.filter {
            $0.date >= lower && $0.date < date && $0.isClosed && $0.sourceKey == day.sourceKey &&
            CivilDate($0.date) != nil && grouped[$0.date]?.count == 1
        }.sorted { $0.date < $1.date }
        let matchingScores = scores.generatedAt == input.generatedAt && scores.asOfDate == input.asOfDate
            ? scores.days.first { $0.date == date && $0.sourceKey == day.sourceKey } : nil
        let activity = activity(day, prior: prior, maximum: maximum,
                                estimated: input.measuredMaxHeartRate == nil, score: matchingScores?.strain)
        let sleep = sleep(day, prior: prior, input: input, selectedDate: selectedDate, grouped: grouped)
        let vitals = VitalKind.allCases.map { kind in
            let value = vitalValue(day, kind: kind)
            let baseline = baseline(prior.compactMap { vitalValue($0, kind: kind) })
            let comparison = compare(value, baseline: baseline)
            let deviation = value.flatMap { value in baseline.flatMap { finite(value - $0.median) } }
            return VitalInsight(kind: kind, value: value, unit: kind.unit, baseline: baseline,
                                deviation: deviation, comparison: comparison,
                                headline: value == nil ? "No reading available" : comparison.label)
        }
        return DailyInsight(date: day.date, sourceKey: day.sourceKey, isClosed: day.isClosed,
                            activity: activity, sleep: sleep, vitals: vitals)
    }

    private static func activity(_ day: DailyInput, prior: [DailyInput], maximum: Double,
                                 estimated: Bool, score: Score?) -> ActivityInsight {
        let zones = observedZones(day, maximum: maximum)
        let observed = zones.map { $0.reduce(0, +) }
        let coverage = observed.flatMap { day.elapsedSeconds > 0 ? finite(min($0 * 60 / day.elapsedSeconds, 1)) : nil }
        let elevated = zones.map { $0.dropFirst().reduce(0, +) }
        let higher = zones.map { $0.suffix(3).reduce(0, +) }
        let usual = baseline(prior.compactMap { previous -> Double? in
            guard isCompleteDay(previous), let zones = observedZones(previous, maximum: maximum),
                  meetsCoverage(zones.reduce(0, +) * 60, duration: previous.dayDurationSeconds) else { return nil }
            return zones.dropFirst().reduce(0, +)
        })
        let comparison: InsightComparison
        let headline: String
        if let observed, let elevated {
            if !day.isClosed {
                comparison = .accumulating
                headline = "\(minutes(elevated)) min of elevated HR so far"
            } else if !isCompleteDay(day) || !meetsCoverage(observed * 60, duration: day.dayDurationSeconds) {
                comparison = .unavailable
                headline = "Partial heart-rate coverage"
            } else {
                comparison = compare(elevated, baseline: usual)
                headline = comparison.label
            }
        } else {
            comparison = .unavailable
            headline = "No heart-rate coverage"
        }
        let coverageText = coverage.map { "\(Int(($0 * 100).rounded()))% of \(day.isClosed ? "the day" : "elapsed time") recorded." }
            ?? "Wear-time coverage is unavailable."
        let historyText = usual.map { "Your completed-day range is \(minutes($0.lower))–\(minutes($0.upper)) min from \($0.sampleCount) prior days." }
            ?? "A usual range needs 7 prior complete days with at least 90% heart-rate coverage."
        let detail = "Time at or above 50% of \(estimated ? "estimated" : "configured") maximum heart rate; includes daily movement, not just workouts. \(coverageText) \(historyText)"
        return ActivityInsight(observedMinutes: observed, coverageFraction: coverage, zoneMinutes: zones ?? [],
                               elevatedMinutes: elevated, higherIntensityMinutes: higher, maxHeartRate: maximum,
                               maximumIsEstimated: estimated, legacyStrain: zones == nil ? nil : score?.value,
                               baseline: usual, comparison: comparison, headline: headline, detail: detail)
    }

    private static func observedZones(_ day: DailyInput, maximum: Double) -> [Double]? {
        guard !blocked(day, signal: .heartRate), day.elapsedSeconds.isFinite, day.elapsedSeconds > 0,
              !day.heartRateBins.isEmpty else { return nil }
        var seconds = 0.0
        var zones = Array(repeating: 0.0, count: 6)
        for bin in day.heartRateBins {
            guard bin.bpm.isFinite, bin.bpm > 0, bin.seconds.isFinite, bin.seconds >= 0 else { return nil }
            seconds += bin.seconds
            let ratio = bin.bpm / maximum
            let zone: Int
            if ratio < 0.5 { zone = 0 }
            else if ratio < 0.6 { zone = 1 }
            else if ratio < 0.7 { zone = 2 }
            else if ratio < 0.8 { zone = 3 }
            else if ratio < 0.9 { zone = 4 }
            else { zone = 5 }
            zones[zone] += bin.seconds / 60
        }
        guard seconds.isFinite, seconds > 0, seconds <= day.elapsedSeconds + 0.000001 else { return nil }
        return zones
    }

    private static func sleep(_ day: DailyInput, prior: [DailyInput], input: InputBundle,
                              selectedDate: CivilDate, grouped: [String: [DailyInput]]) -> SleepInsight {
        let selected = day.sleep?.endTime == nil ? validSleep(day) : completedSleep(day, generatedAt: input.generatedAt)
        let priorSleeps = prior.compactMap { completedSleep($0, generatedAt: input.generatedAt) }
        let lower = selectedDate.adding(days: -6).text
        let known = input.days.filter {
            $0.date >= lower && $0.date <= day.date && $0.sourceKey == day.sourceKey &&
            grouped[$0.date]?.count == 1 && CivilDate($0.date) != nil
        }.sorted { $0.date < $1.date }.compactMap { completedSleep($0, generatedAt: input.generatedAt) }
        let deficit = known.isEmpty ? nil : known.reduce(0) { $0 + max(0, input.sleepTargetMinutes - $1.asleepMinutes) }
        let deviation: Double?
        if let selected, priorSleeps.count >= 7 {
            let x = priorSleeps.reduce(0) { $0 + cos($1.midpointMinute / 1440 * 2 * .pi) } / Double(priorSleeps.count)
            let y = priorSleeps.reduce(0) { $0 + sin($1.midpointMinute / 1440 * 2 * .pi) } / Double(priorSleeps.count)
            if hypot(x, y) > 1e-12 {
                var midpoint = atan2(y, x) * 1440 / (2 * .pi)
                if midpoint < 0 { midpoint += 1440 }
                let difference = abs(selected.midpointMinute - midpoint)
                deviation = min(difference, 1440 - difference)
            } else { deviation = nil }
        } else { deviation = nil }
        let headline: String
        if let selected {
            let shortfall = max(0, input.sleepTargetMinutes - selected.asleepMinutes)
            headline = shortfall > 0 ? "\(minutes(shortfall)) min below your sleep target" : "Your sleep target was met"
        } else { headline = "No sleep reading available" }
        let detail = "\(known.count) of 7 nights recorded as complete. " + (deficit.map {
            "\(minutes($0)) min of shortfall against your \(minutes(input.sleepTargetMinutes)) min target across those nights. Missing nights are excluded; longer nights do not cancel shortfalls."
        } ?? "Sleep shortfall is unavailable until a complete night is recorded.")
        return SleepInsight(asleepMinutes: selected?.asleepMinutes, periodMinutes: selected?.periodMinutes,
                            targetMinutes: input.sleepTargetMinutes,
                            efficiencyPercent: selected.map { 100 * $0.asleepMinutes / $0.periodMinutes },
                            deficitMinutes: deficit, knownNights: known.count, windowNights: 7,
                            midpointDeviationMinutes: deviation, priorNights: priorSleeps.count,
                            lightMinutes: selected?.lightMinutes, deepMinutes: selected?.deepMinutes,
                            remMinutes: selected?.remMinutes, startTime: selected?.startTime, endTime: selected?.endTime,
                            headline: headline, detail: detail)
    }

    private static func validSleep(_ day: DailyInput) -> SleepInput? {
        guard !blocked(day, signal: .sleep), var sleep = day.sleep,
              sleep.asleepMinutes.isFinite, sleep.periodMinutes.isFinite,
              sleep.periodMinutes > 0, sleep.periodMinutes <= 1440,
              sleep.asleepMinutes >= 0, sleep.asleepMinutes <= sleep.periodMinutes,
              sleep.midpointMinute.isFinite, (0..<1440).contains(sleep.midpointMinute) else { return nil }
        if day.issues.contains("invalid_sleep_stages") {
            sleep.lightMinutes = nil; sleep.deepMinutes = nil; sleep.remMinutes = nil
        }
        return sleep
    }

    private static func completedSleep(_ day: DailyInput, generatedAt: String) -> SleepInput? {
        guard let sleep = validSleep(day) else { return nil }
        if let endTime = sleep.endTime {
            guard let end = timestamp(endTime), let generated = timestamp(generatedAt), end <= generated else { return nil }
            if let startTime = sleep.startTime {
                guard let start = timestamp(startTime), start < end else { return nil }
            }
            return sleep
        }
        // Closed legacy dates predate the explicit session timestamps. An open
        // day's legacy sleep cannot establish that the night has finished.
        return day.isClosed ? sleep : nil
    }

    private static func vitalValue(_ day: DailyInput, kind: VitalKind) -> Double? {
        guard !blocked(day, signal: .vital(kind)) else { return nil }
        let value: Double?
        switch kind {
        case .hrv: value = day.rmssdMs
        case .restingHeartRate: value = day.restingHeartRate
        case .oxygenSaturation: value = day.oxygenSaturationPercent
        case .respiratoryRate: value = day.respiratoryRateBrpm
        case .skinTemperature: value = day.skinTemperatureCelsius
        }
        guard let value, value.isFinite else { return nil }
        // These are physical/input bounds, not medical alert thresholds.
        switch kind {
        case .hrv, .restingHeartRate, .respiratoryRate: return value > 0 ? value : nil
        case .oxygenSaturation: return (0...100).contains(value) ? value : nil
        case .skinTemperature: return value >= -273.15 ? value : nil
        }
    }

    private static func baseline(_ values: [Double]) -> PersonalBaseline? {
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.count >= 7 else { return nil }
        func percentile(_ fraction: Double) -> Double {
            let index = Double(sorted.count - 1) * fraction
            let lower = Int(index.rounded(.down)), upper = Int(index.rounded(.up))
            // Interpolating equal decimal values can move by one floating-point
            // unit and falsely classify that same reading outside its own range.
            if sorted[lower] == sorted[upper] { return sorted[lower] }
            let weight = index - Double(lower)
            return sorted[lower] * (1 - weight) + sorted[upper] * weight
        }
        return PersonalBaseline(median: percentile(0.5), lower: percentile(0.1), upper: percentile(0.9),
                                sampleCount: sorted.count, windowDays: 28)
    }

    private static func compare(_ value: Double?, baseline: PersonalBaseline?) -> InsightComparison {
        guard let value else { return .unavailable }
        guard let baseline else { return .buildingBaseline }
        if value < baseline.lower { return .belowUsual }
        if value > baseline.upper { return .aboveUsual }
        return .withinUsual
    }

    private enum Signal { case heartRate, sleep, vital(VitalKind) }

    private static func blocked(_ day: DailyInput, signal: Signal) -> Bool {
        let heartRate: Set<String> = ["invalid_heart_rate", "conflicting_heart_rate"]
        let sleep: Set<String> = ["invalid_sleep", "multiple_main_sleeps"]
        let fields = ["rmssdMs", "restingHeartRate", "oxygenSaturationPercent", "respiratoryRateBrpm", "skinTemperatureCelsius"]
        let vitalIssues = Set(fields.flatMap { ["invalid_\($0)", "conflicting_\($0)"] })
        let known = heartRate.union(sleep).union(vitalIssues).union(["invalid_steps", "overlapping_steps", "invalid_sleep_stages"])
        let relevant: Set<String>
        switch signal {
        case .heartRate: relevant = heartRate
        case .sleep: relevant = sleep
        case .vital(let kind):
            let field: String
            switch kind {
            case .hrv: field = "rmssdMs"
            case .restingHeartRate: field = "restingHeartRate"
            case .oxygenSaturation: field = "oxygenSaturationPercent"
            case .respiratoryRate: field = "respiratoryRateBrpm"
            case .skinTemperature: field = "skinTemperatureCelsius"
            }
            relevant = ["invalid_\(field)", "conflicting_\(field)"]
        }
        return day.issues.contains { !known.contains($0) || relevant.contains($0) }
    }

    private static func isCompleteDay(_ day: DailyInput) -> Bool {
        day.isClosed && day.dayDurationSeconds.isFinite && day.dayDurationSeconds > 0 &&
        abs(day.elapsedSeconds - day.dayDurationSeconds) <= 0.000001
    }

    private static func meetsCoverage(_ observed: Double, duration: Double) -> Bool {
        duration > 0 && observed + 0.000001 >= duration * 0.9
    }

    private static func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
    private static func minutes(_ value: Double) -> String { String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value) }

    private static func timestamp(_ value: String) -> Date? {
        // The value-type parser avoids constructing a formatter (and its ICU
        // state) for every instant in every selected-date history window.
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: value.contains(".")).parse(value)
    }
}
