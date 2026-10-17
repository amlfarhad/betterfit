import Foundation

/// Canonical v1 input. Local dates and duration are resolved by the ingestion layer.
public struct InputBundle: Codable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: String
    public var asOfDate: String
    public var ageYears: Double
    public var sleepTargetMinutes: Double
    public var measuredMaxHeartRate: Double?
    public var days: [DailyInput]

    public init(schemaVersion: Int = 1, generatedAt: String, asOfDate: String, ageYears: Double,
                sleepTargetMinutes: Double = 480, measuredMaxHeartRate: Double? = nil, days: [DailyInput]) {
        self.schemaVersion = schemaVersion; self.generatedAt = generatedAt; self.asOfDate = asOfDate
        self.ageYears = ageYears; self.sleepTargetMinutes = sleepTargetMinutes
        self.measuredMaxHeartRate = measuredMaxHeartRate; self.days = days
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, asOfDate, ageYears, sleepTargetMinutes, measuredMaxHeartRate, days
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try c.decode(String.self, forKey: .generatedAt)
        asOfDate = try c.decode(String.self, forKey: .asOfDate)
        ageYears = try c.decode(Double.self, forKey: .ageYears)
        sleepTargetMinutes = try c.decodeIfPresent(Double.self, forKey: .sleepTargetMinutes) ?? 480
        measuredMaxHeartRate = try c.decodeIfPresent(Double.self, forKey: .measuredMaxHeartRate)
        days = try c.decode([DailyInput].self, forKey: .days)
    }
}

public struct DailyInput: Codable, Sendable {
    public var date: String
    public var sourceKey: String
    public var dayDurationSeconds: Double
    public var elapsedSeconds: Double
    public var isClosed: Bool
    public var steps: Double?
    public var stepsComplete: Bool
    public var heartRateBins: [HeartRateBin]
    public var rmssdMs: Double?
    public var restingHeartRate: Double?
    /// Daily sleep-derived summaries in the API's native units. Missing is never zero-filled.
    public var oxygenSaturationPercent: Double?
    public var respiratoryRateBrpm: Double?
    /// Absolute nightly mean skin/device-derived temperature, not core temperature or a delta.
    public var skinTemperatureCelsius: Double?
    public var sleep: SleepInput?
    public var issues: [String]

    public init(date: String, sourceKey: String, dayDurationSeconds: Double, elapsedSeconds: Double,
                isClosed: Bool, steps: Double? = nil, stepsComplete: Bool = false,
                heartRateBins: [HeartRateBin] = [], rmssdMs: Double? = nil,
                restingHeartRate: Double? = nil, sleep: SleepInput? = nil, issues: [String] = [],
                oxygenSaturationPercent: Double? = nil, respiratoryRateBrpm: Double? = nil,
                skinTemperatureCelsius: Double? = nil) {
        self.date = date; self.sourceKey = sourceKey; self.dayDurationSeconds = dayDurationSeconds
        self.elapsedSeconds = elapsedSeconds; self.isClosed = isClosed; self.steps = steps
        self.stepsComplete = stepsComplete; self.heartRateBins = heartRateBins; self.rmssdMs = rmssdMs
        self.restingHeartRate = restingHeartRate; self.sleep = sleep; self.issues = issues
        self.oxygenSaturationPercent = oxygenSaturationPercent; self.respiratoryRateBrpm = respiratoryRateBrpm
        self.skinTemperatureCelsius = skinTemperatureCelsius
    }
}

public struct HeartRateBin: Codable, Sendable {
    public var bpm: Double
    public var seconds: Double
    public init(bpm: Double, seconds: Double) { self.bpm = bpm; self.seconds = seconds }
}

public struct SleepInput: Codable, Sendable {
    public var asleepMinutes: Double
    public var periodMinutes: Double
    public var midpointMinute: Double
    public var lightMinutes: Double?
    public var deepMinutes: Double?
    public var remMinutes: Double?
    /// UTC ISO 8601 instants; optional for compatibility with existing canonical input.
    public var startTime: String?
    public var endTime: String?
    public init(asleepMinutes: Double, periodMinutes: Double, midpointMinute: Double,
                lightMinutes: Double? = nil, deepMinutes: Double? = nil, remMinutes: Double? = nil,
                startTime: String? = nil, endTime: String? = nil) {
        self.asleepMinutes = asleepMinutes; self.periodMinutes = periodMinutes; self.midpointMinute = midpointMinute
        self.lightMinutes = lightMinutes; self.deepMinutes = deepMinutes; self.remMinutes = remMinutes
        self.startTime = startTime; self.endTime = endTime
    }
}

public enum ScoreStatus: String, Codable, Sendable {
    case available, unavailable, calibrating, provisional, partial, live, insufficientCoverage, outOfDomain
}

public struct Score: Codable, Sendable {
    public let value: Double?
    public let status: ScoreStatus
    public let modelVersion: String
    public let reasons: [String]
    public let components: [String: Double]

    init(value: Double? = nil, status: ScoreStatus, modelVersion: String,
         reasons: [String] = [], components: [String: Double] = [:]) {
        // Every public evaluation validates raw inputs. This final guard also
        // prevents finite-but-extreme input arithmetic from leaking NaN/Inf.
        let overflow = value.map { !$0.isFinite } ?? false
        let invalidComponents = components.values.contains { !$0.isFinite }
        self.value = overflow || invalidComponents ? nil : value
        self.status = overflow || invalidComponents ? .outOfDomain : status
        self.modelVersion = modelVersion
        self.reasons = reasons + (overflow || invalidComponents ? ["arithmeticOverflow"] : [])
        self.components = components.filter { $0.value.isFinite }
    }

    private enum CodingKeys: String, CodingKey { case value, status, modelVersion, reasons, components }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let value { try c.encode(value, forKey: .value) } else { try c.encodeNil(forKey: .value) }
        try c.encode(status, forKey: .status); try c.encode(modelVersion, forKey: .modelVersion)
        try c.encode(reasons, forKey: .reasons); try c.encode(components, forKey: .components)
    }
}

public struct DailyScores: Codable, Sendable {
    public let date: String
    public let sourceKey: String
    public let sleep: Score
    public let sleepRegularity: Score
    public let recovery: Score
    public let strain: Score
}

public struct CollectionDay: Codable, Sendable {
    public let date: String
    public let eligible: Bool
    public let reasons: [String]
}

public struct CollectionProgress: Codable, Sendable {
    public let requiredDays: Int
    public let eligibleDays: Int
    public let windowStart: String
    public let windowEnd: String
    public let days: [CollectionDay]
}

public struct BiologicalAgeResult: Codable, Sendable {
    public let label: String
    public let referenceURL: String
    public let score: Score
    public let collection: CollectionProgress
}

public struct Diagnostic: Codable, Sendable {
    public let code: String
    public let date: String?
    public let message: String
}

public struct ScoreBundle: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: String
    public let asOfDate: String
    public let modelVersions: [String: String]
    public let days: [DailyScores]
    public let biologicalAge: BiologicalAgeResult
    public let diagnostics: [Diagnostic]
}

public struct InputValidationError: Error, Codable, Sendable, CustomStringConvertible {
    public let code: String
    public let path: String
    public let message: String
    public var description: String { "\(code) at \(path): \(message)" }
    init(_ code: String, _ path: String, _ message: String) {
        self.code = code; self.path = path; self.message = message
    }
}
