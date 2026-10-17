import SwiftUI
import FitbitMetrics

struct MetricDetailView: View {
    @Bindable var model: FormModel
    var metric: FormMetric
    @Environment(\.dismiss) private var dismiss
    private var value: Double? { model.value(metric,date:model.selectedDate) }
    var body: some View {
        ZStack {
            FormAtmosphere(tint:metric.tint)
            ScrollView {
                VStack(alignment:.leading,spacing:28) {
                    HStack {
                        Text(metric.title.uppercased()).eyebrow(metric.tint)
                        Spacer()
                        GlyphButton(symbol:"xmark",label:"Close details") { dismiss() }
                    }
                    if model.mode == .demo { Text("SAMPLE DATA").eyebrow(FormPalette.sleep) }
                    VStack(alignment:.leading,spacing:8) {
                        Text(FormModel.dateLabel(model.selectedDate,format:"EEEE, MMMM d")).font(FormType.text(13)).foregroundStyle(FormPalette.secondary)
                        HStack(alignment:.firstTextBaseline,spacing:10) {
                            Text(numberText(value,digits:metric.digits))
                                .font(FormType.display(86)).tracking(-4).monospacedDigit().minimumScaleFactor(0.5)
                            Text(metric.unit).font(FormType.text(19)).foregroundStyle(metric.tint)
                        }.lineLimit(1)
                        Text(statusCaption).font(FormType.medium(14)).foregroundStyle(metric.tint)
                    }
                    VStack(alignment:.leading,spacing:20) {
                        SectionHeading(title:"The last seven days",detail:"SELECT A DAY")
                        HistoryChart(points:model.history(metric,count:7),tint:metric.tint,
                                     maxValue:metric == .recovery || metric == .sleep ? 100 : nil,
                                     selectedDate:model.selectedDate,height:150) { model.selectedDate = $0 }
                        HStack(spacing:4) {
                            ForEach(model.history(metric,count:7)) { point in
                                Button { model.selectedDate = point.date } label: {
                                    Text(FormModel.dateLabel(point.date,format:"d")).font(FormType.medium(11))
                                        .frame(maxWidth:.infinity).frame(height:32)
                                        .foregroundStyle(model.selectedDate == point.date ? FormPalette.background : FormPalette.secondary)
                                        .background(model.selectedDate == point.date ? metric.tint : .clear,in:Capsule())
                                }.buttonStyle(.plain).accessibilityLabel(FormModel.dateLabel(point.date,format:"MMMM d"))
                            }
                        }
                    }.padding(20).formPanel(tint:metric.tint)
                    contributors
                    VStack(alignment:.leading,spacing:13) {
                        Text("BEHIND THE NUMBER").eyebrow()
                        Text(methodTitle).font(FormType.title(22)).tracking(-0.5)
                        Text(methodText).font(FormType.text(14)).foregroundStyle(FormPalette.secondary).lineSpacing(5)
                        if let score = model.score(metric) {
                            Text(score.modelVersion).font(.system(size:10,design:.monospaced)).foregroundStyle(FormPalette.muted)
                            if score.value == nil {
                                Text(score.reasons.filter { !$0.hasPrefix("custom") && !$0.hasPrefix("estimated") }.map(reasonText).joined(separator:" · "))
                                    .font(FormType.text(12)).foregroundStyle(FormPalette.warning).fixedSize(horizontal:false,vertical:true)
                            }
                        }
                    }.padding(.horizontal,2)
                    Text("Calculated on your device. Personal trends, with their context intact.")
                        .font(FormType.text(11)).foregroundStyle(FormPalette.muted).padding(.bottom,18)
                }.padding(24).frame(maxWidth:560).frame(maxWidth:.infinity)
            }.scrollIndicators(.hidden)
        }.foregroundStyle(FormPalette.ink)
    }
    private var statusCaption: String {
        if metric == .strain {
            if model.selectedDate != model.todayKey, model.currentInsight?.activity.comparison == .accumulating { return "Partial recorded day" }
            return model.currentInsight?.activity.headline ?? "Awaiting heart rate"
        }
        if let kind = metric.vitalKind, let vital = model.currentInsight?.vitals.first(where: { $0.kind == kind }) { return vital.headline }
        if let score = model.score(metric) {
            switch score.status {
            case .calibrating: return "Building your baseline · \(model.baselineNights)/7 nights"
            case .provisional: return "Early personal baseline"
            case .insufficientCoverage: return "More heart-rate coverage needed"
            case .live: return "Accumulated so far today"
            case .partial: return "Partial heart-rate coverage"
            case .unavailable, .outOfDomain: return "A score isn’t available for this day"
            case .available: return "Recorded for this day"
            }
        }
        return value == nil ? "No reading for this day" : (model.mode == .demo ? "Synthetic sample measurement" : "Your recorded measurement")
    }
    @ViewBuilder private var contributors: some View {
        VStack(alignment:.leading,spacing:17) {
            SectionHeading(title:metric == .strain ? "Time at intensity" : "Your signals")
            switch metric {
            case .recovery:
                DetailRow(label:"Heart rate variability",value:numberText(model.value(.hrv, date:model.selectedDate)),unit:"ms",tint:metric.tint)
                Hairline()
                DetailRow(label:"Resting heart rate",value:numberText(model.value(.restingHR, date:model.selectedDate)),unit:"bpm",tint:metric.tint)
                Hairline()
                DetailRow(label:"Sleep duration",value:durationText(model.currentInsight?.sleep.asleepMinutes),tint:FormPalette.sleep)
                Hairline()
                DetailRow(label:"Baseline history",value:"\(model.baselineNights)",unit:"nights",tint:metric.tint)
            case .sleep:
                let sleep = model.currentInsight?.sleep
                DetailRow(label:"Time asleep",value:durationText(sleep?.asleepMinutes),tint:metric.tint)
                DetailRow(label:"Time awake",value:durationText(sleep?.periodMinutes.flatMap { period in sleep?.asleepMinutes.map { period - $0 } }),tint:FormPalette.secondary)
                if let period = sleep?.periodMinutes, let asleep = sleep?.asleepMinutes, period > 0 {
                    GeometryReader { g in
                        HStack(spacing:3) {
                            Capsule().fill(metric.tint).frame(width:max(0,g.size.width*asleep/period-2))
                            Capsule().fill(metric.tint.opacity(0.18))
                        }
                    }.frame(height:9).accessibilityLabel("Sleep efficiency \(Int(asleep/period*100)) percent")
                }
                Hairline()
                if let night = model.currentInsight?.sleep {
                    if let light = night.lightMinutes { DetailRow(label:"Light sleep",value:durationText(light),tint:metric.tint) }
                    if let deep = night.deepMinutes { DetailRow(label:"Deep sleep",value:durationText(deep),tint:metric.tint) }
                    if let rem = night.remMinutes { DetailRow(label:"REM sleep",value:durationText(rem),tint:metric.tint) }
                    DetailRow(label:"7-night shortfall",value:durationText(night.deficitMinutes),tint:metric.tint)
                    Text("Against your chosen target across \(night.knownNights) known nights; missing nights are not filled in.").font(FormType.text(11)).foregroundStyle(FormPalette.secondary)
                    if let deviation = night.midpointDeviationMinutes {
                        DetailRow(label:"Midpoint shift",value:numberText(deviation),unit:"min",tint:metric.tint)
                    }
                }
                if model.currentInput?.issues.contains("invalid_sleep_stages") == true {
                    Text("The stage breakdown couldn’t be validated. Your duration and sleep score still use the valid sleep summary.")
                        .font(FormType.text(12)).foregroundStyle(FormPalette.secondary)
                }
                DetailRow(label:"Sleep target",value:durationText(model.sleepTarget),tint:metric.tint)
                DetailRow(label:"Sleep regularity",value:numberText(model.currentDay?.sleepRegularity.value),unit:"/100",tint:metric.tint)
                if model.currentDay?.sleepRegularity.value == nil {
                    Text(model.currentDay?.sleepRegularity.status == .calibrating ? "Regularity needs seven prior nights of sleep timing." : "Sleep timing is unavailable for this day.").font(FormType.text(11)).foregroundStyle(FormPalette.secondary)
                }
            case .strain:
                let activity = model.currentInsight?.activity
                Text("Heart rate as a percentage of your maximum").font(FormType.text(11)).foregroundStyle(FormPalette.secondary)
                ForEach((1...5).reversed(),id:\.self) { zone in
                    let minutes: Double? = activity.flatMap { $0.zoneMinutes.indices.contains(zone) ? $0.zoneMinutes[zone] : nil }
                    HStack(spacing:12) {
                        Text(["", "50–60", "60–70", "70–80", "80–90", "90+"][zone]).font(FormType.label(10)).foregroundStyle(FormPalette.secondary).frame(width:40,alignment:.leading)
                        GeometryReader { g in
                            Capsule().fill(.white.opacity(0.04))
                            Capsule().fill(metric.tint.opacity(0.4+Double(zone)*0.12))
                                .frame(width:g.size.width*min(1,(minutes ?? 0)/60))
                        }.frame(height:5)
                        Text("\(numberText(minutes)) min")
                            .font(FormType.medium(11)).monospacedDigit().frame(width:52,alignment:.trailing)
                    }
                }
                Hairline()
                DetailRow(label:"Heart-rate coverage",value:activity?.coverageFraction.map { numberText($0*100) } ?? "—",unit:"%",tint:metric.tint)
                if let baseline = activity?.baseline {
                    DetailRow(label:"Usual full day",value:"\(numberText(baseline.lower))–\(numberText(baseline.upper))",unit:"min",tint:metric.tint)
                    Text("From \(baseline.sampleCount) prior days with at least 90% recording coverage. The range is descriptive, not a target.").font(FormType.text(11)).foregroundStyle(FormPalette.secondary)
                } else {
                    Text("A usual-day range needs seven prior complete days with at least 90% heart-rate coverage.").font(FormType.text(11)).foregroundStyle(FormPalette.secondary)
                }
                DetailRow(label:"Earlier strain scale",value:numberText(model.score(.strain)?.value,digits:1),unit:"/ 21",tint:FormPalette.secondary)
                Text("This custom score measures accumulated heart-rate load, not danger or a percentage of your limit. About six hours at 50–60% of maximum HR can produce 18, even without a hard workout. Bars above are capped at 60 min.")
                    .font(FormType.text(11)).foregroundStyle(FormPalette.secondary).fixedSize(horizontal:false,vertical:true)
            default:
                DetailRow(label:metric.shortTitle,value:numberText(value, digits: metric.digits),unit:metric.unit,tint:metric.tint)
                if let kind = metric.vitalKind, let vital = model.currentInsight?.vitals.first(where: { $0.kind == kind }), let baseline = vital.baseline {
                    DetailRow(label:"Your usual range",value:"\(numberText(baseline.lower,digits:metric.digits))–\(numberText(baseline.upper,digits:metric.digits))",unit:metric.unit,tint:metric.tint)
                    DetailRow(label:"Change from your median",value:numberText(vital.deviation,digits:1),unit:metric == .oxygen ? "pp" : metric.unit,tint:metric.tint)
                    Text("Based on \(baseline.sampleCount) prior nights. Personal ranges are descriptive, not clinical thresholds.").font(FormType.text(11)).foregroundStyle(FormPalette.secondary)
                }
                Hairline()
                Text(model.mode == .demo ? "Synthetic data · experience preview" : "Google Health · reconciled wearable readings").font(FormType.text(12)).foregroundStyle(FormPalette.secondary)
            }
        }.padding(21).formPanel(tint:metric.tint)
    }
    private var methodTitle: String {
        switch metric { case .recovery: "Relative to you."; case .sleep: "Duration. Continuity. Rhythm."
        case .strain: "Effort, accumulated."; default: "One signal. More context." }
    }
    private var methodText: String {
        switch metric {
        case .recovery: "Recovery compares today’s HRV and resting heart rate with your previous 28 days, using a robust personal baseline. A score of 70 represents baseline HRV and resting heart rate with your sleep target met. Short sleep lowers it; higher means more favorable signals relative to your history, not a percentage of physical capacity. Seven prior nights unlock a provisional result; 21 establish a fuller baseline. This is BetterFit’s wellness estimate."
        case .sleep: "80% of this score reflects time asleep against your target. 20% reflects sleep efficiency. Regularity is reported separately, so an irregular bedtime cannot silently change the score’s weighting. This is a custom app score."
        case .strain: "Activity counts observed minutes at or above 50% of your maximum heart rate; higher intensity starts at 70%. The maximum is estimated as 208 − 0.7 × age unless a measured value is supplied. This can include ordinary movement or elevated resting heart rate, not just workouts. Gaps over 60 seconds are excluded. Coverage is the fraction of elapsed day with usable readings. Neither the minutes nor the legacy 0–21 strain score measure muscular load or tell you whether exercise is safe."
        case .hrv: "Nightly RMSSD describes beat-to-beat timing variation. BetterFit uses the daily value supplied by Google Health. Your own longer-term pattern is the comparison used by Recovery."
        case .restingHR: "Your resting heart rate comes from Google Health’s daily wearable summary. The calculation method is tracked so a change in source does not silently become a new personal baseline."
        case .oxygen: "Mean overnight oxygen saturation supplied by Google Health, in percent. The usual range is your prior 28 days’ 10th–90th percentiles after at least seven valid nights; it is not a clinical reference range."
        case .breathing: "Nightly breaths per minute from Google Health. Differences are compared with your own prior nights, without assigning a diagnosis. Baselines exclude today and days from a different device source."
        case .temperature: "Your Air’s average overnight skin temperature in Celsius, not core body temperature or a fever reading. Sensor contact and surroundings can affect it. The difference from your personal median is calculated locally."
        case .steps: "Steps are summed from fully reconciled intervals. Overlapping records and incomplete days are flagged. Biological Age uses seven finished local days, rather than extrapolating today’s activity."
        }
    }
}

struct DetailRow: View {
    var label:String
    var value:String
    var unit:String = ""
    var tint:Color = FormPalette.ink
    var body: some View {
        HStack(alignment:.firstTextBaseline,spacing:12) {
            Text(label).font(FormType.text(13)).foregroundStyle(FormPalette.secondary)
            Spacer(minLength:8)
            HStack(alignment:.firstTextBaseline,spacing:4) {
                Text(value).font(FormType.medium(20)).monospacedDigit().foregroundStyle(tint)
                if !unit.isEmpty { Text(unit).font(FormType.text(11)).foregroundStyle(FormPalette.secondary) }
            }.lineLimit(1).minimumScaleFactor(0.65)
        }
    }
}

func reasonText(_ reason:String) -> String {
    switch reason {
    case "missingDay": "No recorded day"
    case "incompleteDay", "dayNotClosed", "historicalDayNotClosed": "Day is not complete"
    case "missingSteps": "Step total missing"
    case "incompleteSteps": "Step query incomplete"
    case "insufficientHeartRateCoverage", "heartRateCoverageBelow90Percent": "Less than 90% HR coverage"
    case "sourceChanged", "sourceMismatch", "inconsistentSource": "Source changed"
    case "insufficientBaseline": "Seven prior nights required"
    case "missingHRV", "missingRMSSD": "HRV missing"
    case "missingRestingHeartRate": "Resting heart rate missing"
    case "missingSleep": "Sleep missing"
    case "missingHeartRate": "Heart rate missing"
    case "inputIssues": "Input quality needs attention"
    case "timezone_offset_mismatch": "Time zone changed"
    case "heartRateCoverageBelow80Percent": "Less than 80% HR coverage"
    case "cardiovascularLoadOnly": "Cardiovascular effort only"
    case "undefinedCircularBaseline": "Sleep timing varies too widely for a baseline"
    case "insufficientConsecutiveDays": "Seven consecutive complete days required"
    case "ageBelow20": "The model is intended for adults aged 20 and older"
    case "outsideProductDisplayRange": "The estimate falls outside the displayable range"
    default: reason.replacingOccurrences(of:"([a-z])([A-Z])",with:"$1 $2",options:.regularExpression)
            .replacingOccurrences(of:"_",with:" ").capitalized
    }
}
