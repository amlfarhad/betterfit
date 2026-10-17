import SwiftUI

/// Restoring a saved session is separate from first-time onboarding. Never offer
/// a fresh OAuth flow while the existing account's cache is still opening.
struct SessionRestoreView: View {
    @Bindable var model: FormModel
    private var isLoading: Bool { model.isLoadingSavedSource || model.isRefreshing }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Your day.", eyebrow: "BetterFit", model: model)
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small).tint(FormPalette.recovery)
                        Text("Opening your saved readings…").font(FormType.text(12)).foregroundStyle(FormPalette.secondary)
                    }
                    ForEach(0..<3) { index in
                        VStack(alignment: .leading, spacing: 20) {
                            Capsule().fill(.white.opacity(0.07)).frame(width: 94, height: 9)
                            Capsule().fill(.white.opacity(0.1)).frame(width: index == 0 ? 160 : 120, height: 34)
                            Capsule().fill(.white.opacity(0.05)).frame(height: 7)
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).formPanel()
                    }.accessibilityHidden(true)
                } else {
                    Text(model.needsReauthorization ? "Renew Google access" : "Your account is saved")
                        .font(FormType.title(24))
                    Text(model.syncError ?? (model.needsReauthorization
                        ? "Your saved account needs Google access renewed to update readings."
                        : "Readings couldn’t be opened yet. Try loading them again."))
                        .font(FormType.text(14)).foregroundStyle(FormPalette.secondary).lineSpacing(4)
                    Button { Task {
                        if model.needsReauthorization { await model.connect() }
                        else { await model.refresh() }
                    } } label: {
                        Text(model.needsReauthorization ? "Renew Google access" : "Try again")
                            .font(FormType.medium(14)).foregroundStyle(FormPalette.background)
                            .frame(maxWidth: .infinity).padding(.vertical, 17).background(FormPalette.ink, in: Capsule())
                    }.buttonStyle(PressStyle())
                    Button("Connection options") { model.showConnection = true }
                        .font(FormType.medium(12)).foregroundStyle(FormPalette.secondary)
                }
            }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }.scrollIndicators(.hidden).accessibilityIdentifier("session_restore")
    }
}

struct WelcomeView: View {
    @Bindable var model: FormModel
    @Binding var importing: Bool
    @Environment(\.formStaticRendering) private var staticRendering
    var body: some View {
        if staticRendering {
            GeometryReader { g in content.frame(width:g.size.width).fixedSize(horizontal:false,vertical:true) }.clipped()
        } else { ScrollView { content }.scrollIndicators(.hidden) }
    }
    private var content: some View {
            VStack(alignment:.leading,spacing:0) {
                FormWordmark().padding(.top,22)
                ZStack {
                    ScoreGauge(value:nil,progress:0.79,tint:FormPalette.recovery,size:210,caption:"",showsValue:false)
                        .rotationEffect(.degrees(-12))
                    Circle().stroke(FormPalette.strain.opacity(0.24),lineWidth:1).frame(width:242,height:242)
                    Circle().stroke(FormPalette.sleep.opacity(0.13),lineWidth:0.7).frame(width:273,height:273)
                    FormMark().stroke(FormPalette.ink,style:StrokeStyle(lineWidth:2,lineCap:.round)).frame(width:38,height:38)
                        .background(FormPalette.background,in:Circle()).padding(.bottom,4)
                }.frame(maxWidth:.infinity).frame(height:305).padding(.top,22).accessibilityHidden(true)
                Text("A clearer picture\nof you.").font(FormType.title(39)).tracking(-1.5).fixedSize(horizontal:false,vertical:true)
                Text("Recovery, effort, sleep and the long view.\nYour Air’s signals, thoughtfully connected.")
                    .font(FormType.text(14)).foregroundStyle(FormPalette.secondary).lineSpacing(5).padding(.top,17)
                HStack(spacing:15) {
                    feature("ON DEVICE",color:FormPalette.recovery)
                    feature("NO SUBSCRIPTION",color:FormPalette.strain)
                }.padding(.top,23)
                if let error = model.syncError { InlineNotice(text:error,tint:FormPalette.warning).padding(.top,16) }
                Button { Task { await model.connect() } } label: {
                    HStack(spacing:10) {
                        if model.isRefreshing { ProgressView().controlSize(.small).tint(FormPalette.background) }
                        Text(model.isRefreshing ? (model.mode == .connected ? "Downloading readings…" : "Connecting…") : "Connect Google Health")
                        if !model.isRefreshing { Image(systemName:"arrow.right").font(.system(size:13)) }
                    }.font(FormType.medium(14)).foregroundStyle(FormPalette.background)
                        .frame(maxWidth:.infinity).padding(.vertical,17)
                        .background(FormPalette.ink,in:Capsule())
                }.buttonStyle(PressStyle()).disabled(model.isRefreshing).padding(.top,32)
                Button { importing = true } label: {
                    Text("Import your account snapshot").font(FormType.medium(13)).foregroundStyle(FormPalette.secondary)
                        .frame(maxWidth:.infinity).padding(.vertical,16)
                }.buttonStyle(.plain)
                Button { model.exploreDemo() } label: {
                    HStack(spacing:6) { Text("Explore with sample data"); Image(systemName:"arrow.up.right").font(.system(size:10)) }
                        .font(FormType.text(12)).foregroundStyle(FormPalette.muted).frame(maxWidth:.infinity).padding(.vertical,7)
                }.buttonStyle(.plain)
                Text("Read-only access. Your health data stays in your private app storage. No AI service.")
                    .font(FormType.text(10)).foregroundStyle(FormPalette.muted).multilineTextAlignment(.center)
                    .lineSpacing(3).frame(maxWidth:.infinity).padding(.top,24)
            }.padding(.horizontal,28).padding(.bottom,32).frame(maxWidth:480).frame(maxWidth:.infinity)
    }
    private func feature(_ title:String,color:Color) -> some View {
        HStack(spacing:6) { StatusDot(color:color); Text(title).font(FormType.label(8)).tracking(1) }.foregroundStyle(FormPalette.secondary)
    }
}

struct ConnectionView: View {
    @Bindable var model: FormModel
    @Binding var importing: Bool
    @Environment(\.dismiss) private var dismiss
    @ViewState private var confirmDisconnect = false
    var body: some View {
        ZStack {
            FormAtmosphere()
            ScrollView {
                VStack(alignment:.leading,spacing:27) {
                    HStack { FormWordmark(small:true); Spacer(); GlyphButton(symbol:"xmark",label:"Close connection") { dismiss() } }
                    Text("Your connection.").font(FormType.title(31)).tracking(-1)
                    VStack(alignment:.leading,spacing:18) {
                        HStack(spacing:12) {
                            Image(systemName:"waveform.path").font(.system(size:24,weight:.light)).foregroundStyle(FormPalette.recovery)
                            VStack(alignment:.leading,spacing:4) {
                                Text(model.mode == .demo ? "Sample experience" : "Fitbit Air").font(FormType.title(19))
                                Text(model.modeLabel).font(FormType.text(12)).foregroundStyle(FormPalette.secondary)
                            }
                            Spacer()
                            StatusDot(color:model.mode == .connected ? FormPalette.recovery : FormPalette.age)
                        }
                        Hairline()
                        freshness("Latest measurement",date:model.lastMeasured)
                        freshness("Last checked",date:model.lastChecked)
                        Text("Google Health uploads your Air’s readings first. BetterFit checks the cloud when open and when iOS allows background refresh.")
                            .font(FormType.text(12)).foregroundStyle(FormPalette.secondary).lineSpacing(4)
                        if let error = model.syncError { Text(error).font(FormType.text(12)).foregroundStyle(FormPalette.warning) }
                        Button { Task { await model.refresh() } } label: {
                            HStack(spacing:8) {
                                if model.isRefreshing { ProgressView().controlSize(.small).tint(FormPalette.recovery) }
                                else { Image(systemName:"arrow.clockwise") }
                                Text(model.isRefreshing ? "Checking readings…" : "Refresh readings")
                            }.font(FormType.medium(12)).foregroundStyle(FormPalette.recovery)
                                .frame(maxWidth:.infinity).frame(height:42).background(FormPalette.recovery.opacity(0.075),in:Capsule())
                        }.buttonStyle(PressStyle()).disabled(model.isRefreshing)
                    }.padding(21).formPanel(tint:FormPalette.recovery)
                    VStack(alignment:.leading,spacing:16) {
                        Text("SLEEP TARGET").eyebrow(FormPalette.sleep)
                        HStack {
                            Text(durationText(model.sleepTarget)).font(FormType.display(38)).tracking(-1)
                            Spacer()
                            GlyphButton(symbol:"minus",label:"Reduce sleep target",color:FormPalette.sleep) { model.updateSleepTarget(max(360,model.sleepTarget-15)) }
                            GlyphButton(symbol:"plus",label:"Increase sleep target",color:FormPalette.sleep) { model.updateSleepTarget(min(720,model.sleepTarget+15)) }
                        }
                        Text("Adjust in 15-minute steps. Your scores recalculate locally.").font(FormType.text(11)).foregroundStyle(FormPalette.secondary)
                    }.padding(21).formPanel(tint:FormPalette.sleep)
                    VStack(alignment:.leading,spacing:0) {
                        actionRow("Connect Google Health",subtitle:model.configurationAvailable ? "Secure, read-only Google sign-in" : "iOS client configuration required",symbol:"link") {
                            Task { await model.connect() }
                        }
                        Hairline()
                        actionRow("Import a snapshot",subtitle:"Open your engine-input.json export",symbol:"square.and.arrow.down") { dismiss(); importing = true }
                        Hairline()
                        actionRow("Explore sample data",subtitle:"A clearly labeled, synthetic preview",symbol:"sparkle") { model.exploreDemo(); dismiss() }
                    }.padding(.horizontal,19).formPanel()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("YOUR LOCK SCREEN").eyebrow()
                        Text((Bundle.main.object(forInfoDictionaryKey: "FORM_APP_GROUP") as? String)?.isEmpty == false ? "Touch and hold your Lock Screen, choose Customize, then Add Widgets. Find BetterFit for circular Recovery, Activity and Sleep, or a compact summary." : "Widgets aren’t available in this installed build.")
                            .font(FormType.text(13)).foregroundStyle(FormPalette.secondary).lineSpacing(4)
                        Text("Widgets show the latest saved readings. Activity fills against your usual completed day after enough history; it is not a daily target. Updates depend on Google uploads and iOS background scheduling.")
                            .font(FormType.text(12)).foregroundStyle(FormPalette.secondary).lineSpacing(3)
                    }.padding(21).formPanel()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("WHAT YOUR AIR CAN TELL US").eyebrow()
                        Text("Heart rate, sleep, HRV, steps, oxygen, breathing and overnight skin temperature when Google supplies them. Personal range changes are highlighted without diagnosing illness.")
                            .font(FormType.text(13)).foregroundStyle(FormPalette.secondary).lineSpacing(4)
                        Text("Blood pressure and heart-rhythm diagnoses cannot be inferred from these summary readings. BetterFit doesn’t invent those measurements or treat a quiet dashboard as an all-clear.")
                            .font(FormType.text(12)).foregroundStyle(FormPalette.secondary).lineSpacing(4)
                        Link("Google Health data availability ↗", destination: URL(string: "https://developers.google.com/health/data-types/vitals")!)
                            .font(FormType.medium(12)).foregroundStyle(FormPalette.strain)
                    }.padding(21).formPanel()
                    Text("PRIVATE BY DESIGN").eyebrow()
                    Text("Calculations run on your device. Sign-in tokens live in Keychain; your readings are stored locally. BetterFit does not send your health data to a scoring service.")
                        .font(FormType.text(13)).foregroundStyle(FormPalette.secondary).lineSpacing(4)
                    Button { confirmDisconnect = true } label: {
                        Text("Disconnect & remove local data").font(FormType.medium(12)).foregroundStyle(FormPalette.warning)
                            .frame(maxWidth:.infinity).padding(.vertical,16)
                    }.buttonStyle(.plain)
                }.padding(24).frame(maxWidth:540).frame(maxWidth:.infinity)
            }.scrollIndicators(.hidden)
        }.foregroundStyle(FormPalette.ink)
            .confirmationDialog("Remove BetterFit’s local readings and sign-in? Your Google Health account will be unchanged.",isPresented:$confirmDisconnect,titleVisibility:.visible) {
                Button("Remove local data",role:.destructive) { Task { await model.disconnect() } }
                Button("Cancel",role:.cancel) { }
            }
    }
    private func freshness(_ title:String,date:Date?) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text(title.uppercased()).font(FormType.label(8)).tracking(1).foregroundStyle(FormPalette.muted)
            Text(date.map { $0.formatted(date:.abbreviated,time:.shortened) } ?? "Not available")
                .font(FormType.medium(13)).foregroundStyle(FormPalette.ink)
        }
    }
    private func actionRow(_ title:String,subtitle:String,symbol:String,action:@escaping () -> Void) -> some View {
        Button(action:action) {
            HStack(spacing:12) {
                Image(systemName:symbol).font(.system(size:16)).foregroundStyle(FormPalette.secondary).frame(width:20)
                VStack(alignment:.leading,spacing:4) {
                    Text(title).font(FormType.medium(13)).foregroundStyle(FormPalette.ink)
                    Text(subtitle).font(FormType.text(10)).foregroundStyle(FormPalette.secondary)
                }
                Spacer(minLength:8)
                Image(systemName:"chevron.right").font(.system(size:9)).foregroundStyle(FormPalette.muted)
            }.padding(.vertical,18).contentShape(Rectangle())
        }.buttonStyle(PressStyle())
    }
}
