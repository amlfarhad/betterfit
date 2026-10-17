import Foundation

public enum MetricsEngine {
    public static let modelVersions = [
        "sleep": "app-sleep-1.0.0",
        "sleepRegularity": "app-sleep-regularity-1.0.0",
        "recovery": "app-recovery-1.0.0",
        "strain": "edwards-app-strain-1.0.0",
        "biologicalAge": "moveit-age-2025-sample-sd-1.0.0"
    ]

    /// Decode, validate, calculate, and encode deterministically. Missing scores
    /// are encoded as explicit JSON nulls; invalid bundles throw before scoring.
    public static func evaluate(json: Data) throws -> Data {
        let input = try JSONDecoder().decode(InputBundle.self, from: json)
        let output = try evaluate(input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(output)
    }

    public static func evaluate(_ input: InputBundle) throws -> ScoreBundle {
        try InputValidator.validate(input)
        let sorted = input.days.sorted { $0.date < $1.date }
        let days = sorted.map { day in
            DailyScores(date: day.date, sourceKey: day.sourceKey,
                        sleep: sleepScore(day, target: input.sleepTargetMinutes),
                        sleepRegularity: regularityScore(day, history: sorted),
                        recovery: recoveryScore(day, history: sorted, target: input.sleepTargetMinutes),
                        strain: strainScore(day, maximum: input.measuredMaxHeartRate ?? 208 - 0.7 * input.ageYears,
                                            estimatedMaximum: input.measuredMaxHeartRate == nil,
                                            isCurrentDay: day.date == input.asOfDate))
        }
        var diagnostics = sorted.flatMap { day in
            day.issues.map { Diagnostic(code: "inputIssue", date: day.date, message: $0) }
        }
        diagnostics.append(Diagnostic(code: "movementProxyLimitations", date: nil,
                                      message: "Movement-derived proxy for PhenoAge; not laboratory PhenoAge, tissue age, or a clinically validated Fitbit estimate. Sample SD is an explicit implementation convention."))
        return ScoreBundle(schemaVersion: 1, generatedAt: input.generatedAt, asOfDate: input.asOfDate,
                           modelVersions: modelVersions, days: days,
                           biologicalAge: biologicalAge(input, history: sorted), diagnostics: diagnostics)
    }

    private static func sleepScore(_ day: DailyInput, target: Double) -> Score {
        let version = modelVersions["sleep"]!
        let issues = blockingIssues(day, for: .sleep)
        guard issues.isEmpty else {
            return Score(status: .unavailable, modelVersion: version, reasons: ["inputIssues"] + issues)
        }
        guard let sleep = day.sleep else {
            return Score(status: .unavailable, modelVersion: version, reasons: ["missingSleep"])
        }
        let adequacy = min(sleep.asleepMinutes / target, 1)
        let efficiency = sleep.asleepMinutes / sleep.periodMinutes
        let durationComponent = 80 * adequacy
        let continuityComponent = 20 * min(efficiency / 0.9, 1)
        return Score(value: clamp(durationComponent + continuityComponent, 0, 100), status: .available,
                     modelVersion: version, reasons: ["customHeuristic"],
                     components: ["asleepMinutes": sleep.asleepMinutes, "periodMinutes": sleep.periodMinutes,
                                  "targetMinutes": target, "durationPoints": durationComponent,
                                  "continuityPoints": continuityComponent, "sleepEfficiency": efficiency])
    }

    private static func priorHistory(_ day: DailyInput, _ history: [DailyInput]) -> [DailyInput] {
        let lowerBound = CivilDate(day.date)!.adding(days: -28)
        return history.filter { $0.isClosed && CivilDate($0.date)! >= lowerBound && $0.date < day.date && $0.sourceKey == day.sourceKey }
    }

    private static func regularityScore(_ day: DailyInput, history: [DailyInput]) -> Score {
        let version = modelVersions["sleepRegularity"]!
        let prior = priorHistory(day, history).filter { blockingIssues($0, for: .sleep).isEmpty }.compactMap(\.sleep)
        var components = ["baselineNights": Double(prior.count)]
        let issues = blockingIssues(day, for: .sleep)
        guard issues.isEmpty else {
            return Score(status: .unavailable, modelVersion: version, reasons: ["inputIssues"] + issues, components: components)
        }
        guard let sleep = day.sleep else {
            return Score(status: .unavailable, modelVersion: version, reasons: ["missingSleep"], components: components)
        }
        guard prior.count >= 7 else {
            return Score(status: .calibrating, modelVersion: version, reasons: ["insufficientBaseline"], components: components)
        }
        let angles = prior.map { $0.midpointMinute / 1440 * 2 * Double.pi }
        let x = angles.reduce(0) { $0 + cos($1) } / Double(angles.count)
        let y = angles.reduce(0) { $0 + sin($1) } / Double(angles.count)
        let concentration = hypot(x, y)
        components["baselineConcentration"] = concentration
        guard concentration > 1e-12 else {
            return Score(status: .unavailable, modelVersion: version, reasons: ["undefinedCircularBaseline"], components: components)
        }
        var baseline = atan2(y, x) * 1440 / (2 * Double.pi)
        if baseline < 0 { baseline += 1440 }
        let absoluteDifference = abs(sleep.midpointMinute - baseline)
        let deviation = min(absoluteDifference, 1440 - absoluteDifference)
        components["baselineMidpointMinute"] = baseline
        components["circularDeviationMinutes"] = deviation
        return Score(value: 100 * exp(-0.5 * pow(deviation / 60, 2)), status: .available,
                     modelVersion: version, reasons: ["customHeuristic"], components: components)
    }

    private static func recoveryScore(_ day: DailyInput, history: [DailyInput], target: Double) -> Score {
        let version = modelVersions["recovery"]!
        let prior = priorHistory(day, history).filter {
            $0.rmssdMs != nil && $0.restingHeartRate != nil && blockingIssues($0, for: .recovery).isEmpty
        }
        var components: [String: Double] = ["baselineNights": Double(prior.count)]
        let issues = blockingIssues(day, for: .recovery)
        guard issues.isEmpty else {
            return Score(status: .unavailable, modelVersion: version, reasons: ["inputIssues"] + issues, components: components)
        }
        var missing: [String] = []
        if day.rmssdMs == nil { missing.append("missingRMSSD") }
        if day.restingHeartRate == nil { missing.append("missingRestingHeartRate") }
        if day.sleep == nil { missing.append("missingSleep") }
        guard let hrv = day.rmssdMs, let rhr = day.restingHeartRate, let sleep = day.sleep else {
            return Score(status: .unavailable, modelVersion: version, reasons: missing, components: components)
        }
        guard prior.count >= 7 else {
            return Score(status: .calibrating, modelVersion: version, reasons: ["insufficientBaseline"], components: components)
        }
        let logHRV = prior.map { log($0.rmssdMs!) }
        let restingRates = prior.map { $0.restingHeartRate! }
        let centerHRV = median(logHRV)
        let centerRHR = median(restingRates)
        let scaleHRV = max(1.4826 * median(logHRV.map { abs($0 - centerHRV) }), 0.1)
        let scaleRHR = max(1.4826 * median(restingRates.map { abs($0 - centerRHR) }), 3)
        let h = clamp((log(hrv) - centerHRV) / scaleHRV, -3, 3)
        let r = clamp((centerRHR - rhr) / scaleRHR, -3, 3)
        let sleepPenalty = 20 * (1 - min(sleep.asleepMinutes / target, 1))
        components.merge(["logRMSSDCenter": centerHRV, "logRMSSDScale": scaleHRV,
                          "restingHeartRateCenter": centerRHR, "restingHeartRateScale": scaleRHR,
                          "rmssdMs": hrv, "restingHeartRate": rhr, "hrvZ": h, "rhrZ": r,
                          "sleepPenalty": sleepPenalty]) { _, new in new }
        return Score(value: clamp(70 + 10 * (0.7 * h + 0.3 * r) - sleepPenalty, 0, 100),
                     status: prior.count >= 21 ? .available : .provisional, modelVersion: version,
                     reasons: ["customHeuristic"], components: components)
    }

    private static func strainScore(_ day: DailyInput, maximum: Double, estimatedMaximum: Bool,
                                    isCurrentDay: Bool) -> Score {
        let version = modelVersions["strain"]!
        let observed = day.heartRateBins.reduce(0) { $0 + $1.seconds }
        let coverage = day.elapsedSeconds > 0 ? min(observed / day.elapsedSeconds, 1) : 0
        var zoneMinutes = Array(repeating: 0.0, count: 6)
        for bin in day.heartRateBins {
            let ratio = bin.bpm / maximum
            let weight: Int
            if ratio < 0.5 { weight = 0 }
            else if ratio < 0.6 { weight = 1 }
            else if ratio < 0.7 { weight = 2 }
            else if ratio < 0.8 { weight = 3 }
            else if ratio < 0.9 { weight = 4 }
            else { weight = 5 }
            zoneMinutes[weight] += bin.seconds / 60
        }
        let load = zoneMinutes.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element }
        var components = ["rawLoad": load, "coverage": coverage, "observedSeconds": observed,
                          "elapsedSeconds": day.elapsedSeconds, "maxHeartRate": maximum]
        for zone in 0...5 { components["zone\(zone)Minutes"] = zoneMinutes[zone] }
        var reasons = ["customDisplayMapping", "cardiovascularLoadOnly"]
        if estimatedMaximum { reasons.append("estimatedMaxHeartRate") }
        let issues = blockingIssues(day, for: .heartRate)
        guard issues.isEmpty else {
            return Score(status: .unavailable, modelVersion: version,
                         reasons: reasons + ["inputIssues"] + issues, components: components)
        }
        guard observed > 0 else {
            return Score(status: .unavailable, modelVersion: version, reasons: reasons + ["missingHeartRate"], components: components)
        }
        guard meetsCoverage(observed: observed, duration: day.elapsedSeconds, threshold: 0.8) else {
            return Score(status: .insufficientCoverage, modelVersion: version, reasons: reasons + ["heartRateCoverageBelow80Percent"], components: components)
        }
        let meets90 = meetsCoverage(observed: observed, duration: day.elapsedSeconds, threshold: 0.9)
        let status: ScoreStatus = !meets90 ? .partial : (day.isClosed ? .available : (isCurrentDay ? .live : .partial))
        if !meets90 { reasons.append("heartRateCoverageBelow90Percent") }
        if !day.isClosed && !isCurrentDay { reasons.append("historicalDayNotClosed") }
        return Score(value: min(21, 21 * log1p(load / 20) / log(31)), status: status,
                     modelVersion: version, reasons: reasons, components: components)
    }

    private static func biologicalAge(_ input: InputBundle, history: [DailyInput]) -> BiologicalAgeResult {
        let version = modelVersions["biologicalAge"]!
        let asOf = CivilDate(input.asOfDate)!
        let dates = (1...7).reversed().map { asOf.adding(days: -$0).text }
        let indexed = Dictionary(uniqueKeysWithValues: history.map { ($0.date, $0) })
        // Anchor collection to the most recent present date in the window. A
        // manual source change starts a new uninterrupted collection period.
        let expectedSource = dates.reversed().compactMap { indexed[$0]?.sourceKey }.first
        let collectionDays = dates.map { date -> CollectionDay in
            guard let day = indexed[date] else { return CollectionDay(date: date, eligible: false, reasons: ["missingDay"]) }
            var reasons: [String] = []
            if !day.isClosed { reasons.append("dayNotClosed") }
            if day.steps == nil { reasons.append("missingSteps") }
            if !day.stepsComplete { reasons.append("incompleteSteps") }
            // Added optional signals do not change movement eligibility. Keep
            // the existing handling of all legacy and unknown quality flags.
            if day.issues.contains(where: { !optionalVitalIssues.contains($0) && $0 != "invalid_sleep_stages" }) { reasons.append("inputIssues") }
            if day.sourceKey != expectedSource { reasons.append("inconsistentSource") }
            let seconds = day.heartRateBins.reduce(0) { $0 + $1.seconds }
            // Closed-day age eligibility always uses the full civil-day length.
            if !meetsCoverage(observed: seconds, duration: day.dayDurationSeconds, threshold: 0.9) {
                reasons.append("heartRateCoverageBelow90Percent")
            }
            return CollectionDay(date: date, eligible: reasons.isEmpty, reasons: reasons)
        }
        let count = collectionDays.filter(\.eligible).count
        let collection = CollectionProgress(requiredDays: 7, eligibleDays: count,
                                             windowStart: dates.first!, windowEnd: dates.last!, days: collectionDays)
        let qualifiers = ["movementDerivedProxy", "notClinicallyValidatedForFitbit", "sampleSDConvention"]
        var components = ["ageYears": input.ageYears, "eligibleDays": Double(count), "requiredDays": 7.0]
        let result: Score
        if input.ageYears < 20 {
            result = Score(status: .outOfDomain, modelVersion: version, reasons: qualifiers + ["ageBelow20"], components: components)
        } else if count < 7 {
            let failures = Array(Set(collectionDays.flatMap(\.reasons))).sorted()
            result = Score(status: .calibrating, modelVersion: version,
                           reasons: qualifiers + ["insufficientConsecutiveDays"] + failures, components: components)
        } else {
            let steps = dates.map { indexed[$0]!.steps! }
            let maximum = steps.max()!
            // Normalize before computing variance to avoid overflow in squared
            // differences of otherwise finite numbers. n−1 is intentional.
            let normalized = maximum > 0 ? steps.map { $0 / maximum } : Array(repeating: 0, count: 7)
            let normalizedMean = normalized.reduce(0, +) / 7
            let sd = maximum * sqrt(normalized.reduce(0) { $0 + pow($1 - normalizedMean, 2) } / 6)
            let value = 4.2390852 + 1.0824163 * input.ageYears - 0.0012294 * maximum + 0.0015739 * sd
            components["maxDailySteps"] = maximum
            components["sampleSDDailySteps"] = sd
            // 0...120 is an app output guard, not a validated scientific range.
            if !value.isFinite || !(0...120).contains(value) {
                result = Score(status: .outOfDomain, modelVersion: version,
                               reasons: qualifiers + ["outsideProductDisplayRange"], components: components)
            } else {
                result = Score(value: value, status: .available, modelVersion: version,
                               reasons: qualifiers, components: components)
            }
        }
        return BiologicalAgeResult(label: "movement-derived biological-age estimate",
                                   referenceURL: "https://doi.org/10.1007/s11357-025-01999-7",
                                   score: result, collection: collection)
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }

    private static func meetsCoverage(observed: Double, duration: Double, threshold: Double) -> Bool {
        // Same one-microsecond integration tolerance as duration validation.
        // Splitting an interval into equal fractional bins cannot change a gate.
        duration > 0 && observed + 0.000001 >= duration * threshold
    }

    private enum Signal { case sleep, heartRate, recovery }

    private static let optionalVitalIssues: Set<String> = [
        "invalid_oxygenSaturationPercent", "conflicting_oxygenSaturationPercent",
        "invalid_respiratoryRateBrpm", "conflicting_respiratoryRateBrpm",
        "invalid_skinTemperatureCelsius", "conflicting_skinTemperatureCelsius"
    ]

    /// Unknown flags fail closed. Known flags only block scores consuming that
    /// signal; a step conflict, for example, does not invalidate sleep.
    private static func blockingIssues(_ day: DailyInput, for signal: Signal) -> [String] {
        let stepIssues: Set<String> = ["invalid_steps", "overlapping_steps"]
        let sleepIssues: Set<String> = ["invalid_sleep", "multiple_main_sleeps"]
        let heartRateIssues: Set<String> = ["invalid_heart_rate", "conflicting_heart_rate"]
        let recoveryIssues: Set<String> = ["invalid_rmssdMs", "conflicting_rmssdMs",
                                          "invalid_restingHeartRate", "conflicting_restingHeartRate"]
        let known = stepIssues.union(sleepIssues).union(heartRateIssues).union(recoveryIssues).union(optionalVitalIssues).union(["invalid_sleep_stages"])
        let relevant: Set<String>
        switch signal {
        case .sleep: relevant = sleepIssues
        case .heartRate: relevant = heartRateIssues
        case .recovery: relevant = sleepIssues.union(recoveryIssues)
        }
        return Array(Set(day.issues.filter { !known.contains($0) || relevant.contains($0) })).sorted()
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? sorted[middle - 1] / 2 + sorted[middle] / 2 : sorted[middle]
    }
}
