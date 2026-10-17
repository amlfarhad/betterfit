import Foundation
import FitbitMetrics

/// Explicit design/demo data. Never used as a fallback for an account failure.
public enum FormDemo {
    public static func input(now: Date = Date()) -> InputBundle {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter(); formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone; formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let todayKey = formatter.string(from: today)
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sleeps: [Double] = [447, 425, 476, 402, 465, 451, 489, 461, 434, 492, 428, 474, 460, 448]
        var days: [DailyInput] = []
        for i in 0..<35 {
            let offset = i - 34
            let date = calendar.date(byAdding: .day, value: offset, to: today)!
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: date)!
            let duration = tomorrow.timeIntervalSince(date)
            let elapsed = offset == 0 ? max(1, now.timeIntervalSince(today)) : duration
            let asleep = offset == 0 ? 472.0 : sleeps[i % sleeps.count]
            let vigorous = min(elapsed * 0.02, Double(8 + i % 18) * 60)
            let moderate = min(elapsed * 0.04, Double(13 + i % 20) * 60)
            let easy = min(elapsed * 0.08, Double(30 + i % 21) * 60)
            let observed = elapsed * 0.972
            days.append(DailyInput(date: formatter.string(from: date), sourceKey: "synthetic-demo:v1",
                dayDurationSeconds: duration, elapsedSeconds: elapsed, isClosed: offset < 0,
                steps: offset == 0 ? 6432 : Double(6700 + (i * 713) % 7300), stepsComplete: offset < 0,
                heartRateBins: [.init(bpm: 68, seconds: max(0, observed-vigorous-moderate-easy)),
                               .init(bpm: 107, seconds: easy), .init(bpm: 138, seconds: moderate),
                               .init(bpm: 163, seconds: vigorous)],
                rmssdMs: offset == 0 ? 68 : Double(49 + (i * 7) % 19),
                restingHeartRate: offset == 0 ? 52 : Double(53 + (i * 3) % 7),
                sleep: SleepInput(asleepMinutes: asleep, periodMinutes: asleep + 24,
                                  midpointMinute: Double(211 + (i * 7) % 44),
                                  lightMinutes: asleep * 0.53, deepMinutes: asleep * 0.19, remMinutes: asleep * 0.28,
                                  startTime: iso.string(from: min(now, date.addingTimeInterval(7 * 3600)).addingTimeInterval(-(asleep + 24) * 60)),
                                  endTime: iso.string(from: min(now, date.addingTimeInterval(7 * 3600)))) ,
                oxygenSaturationPercent: 97 + Double(i % 3) * 0.3,
                respiratoryRateBrpm: 14 + Double(i % 5) * 0.2,
                skinTemperatureCelsius: 33 + Double(i % 4) * 0.15))
        }
        return InputBundle(generatedAt: iso.string(from: now), asOfDate: todayKey, ageYears: 34,
                           sleepTargetMinutes: 480, measuredMaxHeartRate: nil, days: days)
    }
}
