import SwiftUI
import FitbitMetrics

struct AgeView: View {
    @Bindable var model: FormModel
    @ViewState private var expandedMethod = false
    private var result: BiologicalAgeResult? { model.scores?.biologicalAge }
    private var age: Double? { result?.score.value }
    var body: some View {
        VStack(alignment:.leading,spacing:26) {
            PageHeader(title:"The long view.",eyebrow:"Biological age",model:model)
            VStack(spacing:0) {
                if model.mode == .demo {
                    Text("SAMPLE DATA").eyebrow(FormPalette.sleep).padding(.top,4).padding(.bottom,8)
                }
                ZStack {
                    OrbitalIllustration().scaleEffect(1.65).frame(height:155).opacity(0.9)
                    if let age {
                        VStack(spacing:4) {
                            Text(numberText(age,digits:1)).font(FormType.display(82)).tracking(-4)
                            Text("YEARS").eyebrow(FormPalette.age)
                        }.padding(.top,2)
                    }
                }.frame(maxWidth:.infinity).padding(.top,12)
                if age == nil {
                    Text(result?.score.status == .outOfDomain ? "Outside the model." : "A week of you.").font(FormType.title(29)).tracking(-0.7).padding(.top,5)
                    Text(result?.score.status == .outOfDomain ? "An estimate cannot be shown" : "\(result?.collection.eligibleDays ?? 0) of 7 complete days collected")
                        .font(FormType.medium(13)).foregroundStyle(FormPalette.age).padding(.top,9)
                } else {
                    Text(comparison).font(FormType.medium(15)).foregroundStyle(FormPalette.age).padding(.top,9)
                }
                Text("MOVEMENT ESTIMATE").font(FormType.label(9)).tracking(1.8).foregroundStyle(FormPalette.secondary).padding(.top,15)
                if let result {
                    CollectionStrip(days:result.collection.days.map { ($0.date,$0.eligible) }).padding(.top,28)
                }
                Text(collectionExplanation)
                    .font(FormType.text(12)).foregroundStyle(FormPalette.secondary).multilineTextAlignment(.center)
                    .lineSpacing(4).fixedSize(horizontal:false,vertical:true).padding(.top,22)
            }.padding(24).formPanel(tint:FormPalette.age,radius:28)
            VStack(alignment:.leading,spacing:19) {
                SectionHeading(title:"What goes into it",detail:"MOVEIT! AGE")
                DetailRow(label:"Chronological age",value:numberText(model.input?.ageYears),unit:"years",tint:FormPalette.age)
                Hairline()
                DetailRow(label:"Highest daily steps",value:numberText(result?.score.components["maxDailySteps"]),tint:FormPalette.age)
                Hairline()
                DetailRow(label:"Daily step variation",value:numberText(result?.score.components["sampleSDDailySteps"]),unit:"SD",tint:FormPalette.age)
                if age == nil {
                    Text("Weekly inputs are calculated once all seven days qualify.").font(FormType.text(11)).foregroundStyle(FormPalette.secondary)
                }
            }.padding(21).formPanel(tint:FormPalette.age)
            if let result {
                VStack(alignment:.leading,spacing:18) {
                    SectionHeading(title:"Your collection window")
                    ForEach(result.collection.days,id:\.date) { day in
                        HStack(alignment:.top,spacing:11) {
                            Image(systemName:day.eligible ? "checkmark.circle.fill" : "circle.dashed")
                                .font(.system(size:16)).foregroundStyle(day.eligible ? FormPalette.age : FormPalette.muted).padding(.top,2)
                            VStack(alignment:.leading,spacing:4) {
                                Text(FormModel.dateLabel(day.date,format:"EEEE, MMM d")).font(FormType.medium(13))
                                Text(day.eligible ? "Complete steps · sufficient HR coverage" : day.reasons.map(reasonText).joined(separator:" · "))
                                    .font(FormType.text(11)).foregroundStyle(FormPalette.secondary).fixedSize(horizontal:false,vertical:true)
                            }
                            Spacer(minLength:0)
                        }
                    }
                }.padding(.horizontal,3)
            }
            VStack(alignment:.leading,spacing:16) {
                Button { withAnimation(.easeInOut(duration:0.2)) { expandedMethod.toggle() } } label: {
                    HStack {
                        Text("THE SCIENCE & ITS LIMITS").eyebrow(FormPalette.age)
                        Spacer()
                        Image(systemName:expandedMethod ? "minus" : "plus").font(.system(size:13)).foregroundStyle(FormPalette.age)
                    }.padding(.vertical,3).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Text("A movement-based proxy. Fitbit Air accuracy has not been clinically validated.")
                    .font(FormType.text(13)).foregroundStyle(FormPalette.secondary).lineSpacing(4)
                if expandedMethod {
                    Text("BetterFit uses the published MoveIt! Age equation: your chronological age, the highest daily step total and sample standard deviation across seven days. It was developed against PhenoAge using other devices and populations. Sample SD is an explicit implementation convention; the authors’ exact denominator was not available.")
                        .font(FormType.text(13)).foregroundStyle(FormPalette.secondary).lineSpacing(4)
                    Text("A lower estimate is not proof of tissue rejuvenation. A change in walking routine, travel, illness or measurement coverage can change this number. Collection progress describes data readiness, not scientific confidence.")
                        .font(FormType.text(13)).foregroundStyle(FormPalette.secondary).lineSpacing(4)
                    Link(destination:URL(string:"https://doi.org/10.1007/s11357-025-01999-7")!) {
                        HStack { Text("Read the published study"); Image(systemName:"arrow.up.right") }
                            .font(FormType.medium(12)).foregroundStyle(FormPalette.age)
                    }
                    Text(result?.score.modelVersion ?? "moveit-age-2025-sample-sd-1.0.0")
                        .font(.system(size:9,design:.monospaced)).foregroundStyle(FormPalette.muted)
                }
            }.padding(20).formPanel(tint:FormPalette.age,radius:20)
            if model.mode == .demo { Text("SAMPLE DATA · NOT YOUR BIOLOGICAL AGE").eyebrow(FormPalette.sleep) }
        }
    }
    private var comparison: String {
        guard let age, let calendarAge = model.input?.ageYears else { return "" }
        let difference = abs(age-calendarAge)
        return "\(numberText(difference,digits:1)) years \(age < calendarAge ? "below" : "above") your calendar age"
    }
    private var collectionExplanation: String {
        if result?.score.status == .outOfDomain {
            return result?.score.reasons.filter { ["ageBelow20", "outsideProductDisplayRange"].contains($0) }.map(reasonText).joined(separator:". ") ?? "The model cannot give a meaningful estimate from these inputs."
        }
        return age == nil ? "Seven finished days reveal your first estimate. Keep wearing your Air through the day and night." : "A view of your movement patterns, calculated from seven finished days."
    }
}
