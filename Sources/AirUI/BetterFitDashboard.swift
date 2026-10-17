import SwiftUI
import FitbitMetrics

struct TodayView: View {
    @Bindable var model: FormModel
    private var insight: DailyInsight? { model.currentInsight }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            PageHeader(title: model.selectedDate == model.todayKey ? "Your day." : FormModel.dateLabel(model.selectedDate, format: "EEEE"),
                       eyebrow: "BetterFit / " + FormModel.dateLabel(model.selectedDate, format: "MMM d"), model: model)
            dateRail
            if model.mode == .demo { Text("SAMPLE DATA · EXPERIENCE PREVIEW").eyebrow(FormPalette.sleep) }
            if let error = model.syncError { InlineNotice(text: error, tint: FormPalette.warning) }
            recovery
            sleep
            activity
            bodySignals
            Button { model.selectedMetric = .steps } label: {
                HStack {
                    Image(systemName: "figure.walk").font(.system(size: 23)).foregroundStyle(FormPalette.strain)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Daily movement").font(FormType.medium(14))
                        Text(insight?.isClosed == true ? "Recorded steps" : model.selectedDate == model.todayKey ? "Steps so far" : "Partial recorded day").font(FormType.text(11)).foregroundStyle(FormPalette.secondary)
                    }
                    Spacer()
                    Text(numberText(model.value(.steps, date: model.selectedDate))).font(FormType.medium(27)).monospacedDigit()
                    chevron
                }.padding(19).formPanel(tint: FormPalette.strain)
            }.buttonStyle(PressStyle())
            Button { model.tab = .age } label: { AgeTeaser(model: model) }.buttonStyle(PressStyle())
            Button { model.showConnection = true } label: {
                HStack(spacing: 7) {
                    StatusDot(color: FormPalette.secondary)
                    Text(model.measurementCaption).font(FormType.label(9)).tracking(0.7)
                    Spacer(); chevron
                }.foregroundStyle(FormPalette.secondary).padding(.vertical, 8)
            }.buttonStyle(.plain)
        }
    }
    private var dateRail: some View {
        HStack(spacing: 0) {
            ForEach(model.dates, id: \.self) { date in
                Button { model.selectedDate = date } label: {
                    VStack(spacing: 7) {
                        Text(FormModel.dateLabel(date, format: "EEEEE")).font(FormType.label(9)).foregroundStyle(FormPalette.secondary)
                        Text(FormModel.dateLabel(date, format: "d")).font(FormType.medium(13)).monospacedDigit()
                            .frame(width: 32, height: 32)
                            .foregroundStyle(model.selectedDate == date ? FormPalette.background : FormPalette.secondary)
                            .background(model.selectedDate == date ? FormPalette.ink : .clear, in: Circle())
                    }.frame(maxWidth: .infinity).padding(.vertical, 3)
                }.buttonStyle(PressStyle()).accessibilityLabel(FormModel.dateLabel(date, format: "EEEE, MMMM d"))
                    .accessibilityAddTraits(model.selectedDate == date ? .isSelected : [])
            }
        }
    }
    private var recovery: some View {
        let score = model.currentDay?.recovery.value
        let calibrating = model.currentDay?.recovery.status == .calibrating
        return Button { model.selectedMetric = .recovery } label: {
            VStack(alignment: .leading, spacing: 15) {
                cardHeading("RECOVERY", detail: score == nil ? (calibrating ? "BUILDING BASELINE" : "AWAITING SIGNALS") : "/ 100", tint: FormPalette.recovery)
                HStack(spacing: 19) {
                    ZStack {
                        Circle().stroke(FormPalette.recovery.opacity(0.1), lineWidth: 5)
                        Circle().trim(from: 0, to: score.map { $0 / 100 } ?? (calibrating ? Double(min(model.baselineNights, 7)) / 7 : 0))
                            .stroke(FormPalette.recovery, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text(score.map { numberText($0) } ?? (calibrating ? "\(min(model.baselineNights, 7))/7" : "—"))
                            .font(FormType.display(score == nil ? 26 : 34)).monospacedDigit()
                    }.frame(width: 68, height: 68).accessibilityLabel(score.map { "Recovery \(Int($0)) out of 100" } ?? (calibrating ? "\(model.baselineNights) baseline nights" : "Recovery unavailable"))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(score == nil ? (calibrating ? "Getting to know you." : "A signal is missing.") : "Your recovery estimate.")
                            .font(FormType.title(19)).tracking(-0.5)
                        Text(score == nil ? (calibrating ? "Seven prior nights unlock your first score." : "Open to see what’s needed.") : "70 is your baseline reference. HRV, resting heart rate and sleep move it up or down.")
                            .font(FormType.text(12)).foregroundStyle(FormPalette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.padding(20).formPanel(tint: FormPalette.recovery)
        }.buttonStyle(PressStyle())
    }
    private var sleep: some View {
        let sleep = insight?.sleep
        return Button { model.selectedMetric = .sleep } label: {
            VStack(alignment: .leading, spacing: 10) {
                cardHeading(model.selectedDate == model.todayKey ? "LAST NIGHT" : "SLEEP", detail: "SLEEP", tint: FormPalette.sleep)
                HStack(alignment: .firstTextBaseline) {
                    Text(durationText(sleep?.asleepMinutes)).font(FormType.display(39)).tracking(-1.4).monospacedDigit()
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(numberText(model.currentDay?.sleep.value)).font(FormType.medium(21)).foregroundStyle(FormPalette.sleep)
                        Text("SCORE / 100").font(FormType.label(8)).tracking(0.6).foregroundStyle(FormPalette.secondary)
                    }
                }
                progressBar(sleep?.asleepMinutes.map { $0 / model.sleepTarget }, tint: FormPalette.sleep)
                HStack {
                    Text("\(durationText(model.sleepTarget)) target")
                    Spacer()
                    Text(sleep?.efficiencyPercent.map { "\(numberText($0))% sleep efficiency" } ?? "Awaiting a sleep record")
                }.font(FormType.text(11)).foregroundStyle(FormPalette.secondary)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "moon.zzz").foregroundStyle(FormPalette.sleep)
                    Text(sleep?.deficitMinutes.map { "\(durationText($0)) below target across \(sleep?.knownNights ?? 0) known nights this week." } ?? "Your weekly sleep shortfall appears as nights arrive.")
                        .font(FormType.text(12)).foregroundStyle(FormPalette.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(20).formPanel(tint: FormPalette.sleep)
        }.buttonStyle(PressStyle())
    }
    private var activity: some View {
        let activity = insight?.activity
        return Button { model.selectedMetric = .strain } label: {
            VStack(alignment: .leading, spacing: 15) {
                cardHeading("ACTIVITY", detail: insight?.isClosed == true ? "RECORDED DAY" : model.selectedDate == model.todayKey ? "SO FAR TODAY" : "PARTIAL RECORDED DAY", tint: FormPalette.strain)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(numberText(activity?.elevatedMinutes)).font(FormType.display(43)).tracking(-1.5).monospacedDigit()
                    Text("min").font(FormType.text(16)).foregroundStyle(FormPalette.strain)
                    Spacer()
                    Image(systemName: "waveform.path").font(.system(size: 27, weight: .ultraLight)).foregroundStyle(FormPalette.strain)
                }
                Text("With an elevated heart rate").font(FormType.medium(14))
                if let activity, activity.zoneMinutes.count == 6 {
                    GeometryReader { geometry in
                        let total = max(1, activity.zoneMinutes.reduce(0, +))
                        HStack(spacing: 2) {
                            ForEach(0..<6, id: \.self) { zone in
                                RoundedRectangle(cornerRadius: 2).fill(zone == 0 ? .white.opacity(0.07) : FormPalette.strain.opacity(0.3 + Double(zone) * 0.14))
                                    .frame(width: max(0, (geometry.size.width - 10) * activity.zoneMinutes[zone] / total))
                            }
                        }
                    }.frame(height: 7).accessibilityHidden(true)
                }
                HStack {
                    Text("\(numberText(activity?.higherIntensityMinutes)) min at higher intensity")
                    Spacer(minLength: 8)
                    Text(activity?.coverageFraction.map { "\(numberText($0 * 100))% recorded" } ?? "Coverage unavailable")
                }.font(FormType.text(10)).foregroundStyle(FormPalette.secondary)
                Text(activity?.baseline.map { "Your usual full day: \(numberText($0.lower))–\(numberText($0.upper)) min across \($0.sampleCount) prior days." } ?? "Your usual-day range needs 7 complete recorded days.")
                    .font(FormType.text(11)).foregroundStyle(FormPalette.strain).fixedSize(horizontal: false, vertical: true)
                Text("Includes everyday movement, not just exercise. Minutes accumulate; they aren’t a strain limit.")
                    .font(FormType.text(12)).foregroundStyle(FormPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20).formPanel(tint: FormPalette.strain)
        }.buttonStyle(PressStyle())
    }
    private var bodySignals: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                SectionHeading(title: "Your body signals", detail: "OVERNIGHT")
                Text("Compared with your own recent range.").font(FormType.text(12)).foregroundStyle(FormPalette.secondary)
            }
            VStack(spacing: 0) {
                ForEach([FormMetric.hrv, .restingHR, .oxygen, .breathing, .temperature]) { metric in
                    let vital = insight?.vitals.first { $0.kind == metric.vitalKind }
                    Button { model.selectedMetric = metric } label: {
                        HStack(spacing: 12) {
                            Image(systemName: metric.symbol).font(.system(size: 16)).foregroundStyle(metric.tint).frame(width: 22)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(metric.shortTitle).font(FormType.medium(13))
                                Text(vital?.value == nil ? "No reading received" : vital?.baseline.map { "Usual \(numberText($0.lower, digits: metric.digits))–\(numberText($0.upper, digits: metric.digits)) \(metric.unit)" } ?? "Learning your usual range")
                                    .font(FormType.text(10)).foregroundStyle(FormPalette.secondary)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    Text(numberText(vital?.value, digits: metric.digits)).font(FormType.medium(23)).monospacedDigit()
                                    Text(metric.unit).font(FormType.text(9)).foregroundStyle(FormPalette.secondary)
                                }
                                if vital?.comparison == .aboveUsual || vital?.comparison == .belowUsual {
                                    Text(vital?.comparison == .aboveUsual ? "ABOVE USUAL" : "BELOW USUAL").font(FormType.label(8)).foregroundStyle(FormPalette.age)
                                }
                            }
                            chevron
                        }.padding(.vertical, 15)
                    }.buttonStyle(PressStyle())
                    if metric != .temperature { Hairline() }
                }
            }.padding(.horizontal, 18).formPanel()
            Text("Personal ranges need 7 prior nights. A change is an observation, not a diagnosis; readings in range don’t rule out illness.")
                .font(FormType.text(11)).foregroundStyle(FormPalette.secondary).lineSpacing(2)
        }.padding(.top, 7)
    }
    private var chevron: some View { Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(FormPalette.muted) }
    private func cardHeading(_ title: String, detail: String, tint: Color) -> some View {
        HStack { Text(title).eyebrow(tint); Spacer(); Text(detail).font(FormType.label(8)).tracking(0.6).foregroundStyle(FormPalette.secondary); chevron }
    }
    private func progressBar(_ fraction: Double?, tint: Color) -> some View {
        GeometryReader { geometry in
            Capsule().fill(tint.opacity(0.1))
            Capsule().fill(tint.opacity(0.85)).frame(width: geometry.size.width * min(1, max(0, fraction ?? 0)))
        }.frame(height: 5).accessibilityHidden(true)
    }
}
