import AirUI
import BackgroundTasks
import SwiftUI

@main
@MainActor
struct FormApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = FormModel()

    private static let refreshIdentifier = "com.amal.form.refresh"

    var body: some Scene {
        WindowGroup {
            FormRootView(model: model)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { scheduleRefresh() }
        }
        .backgroundTask(.appRefresh(Self.refreshIdentifier)) {
            // A cold background launch may not create a UI scene. Restore the
            // selected source before refresh; startup is idempotent when the
            // foreground view has already initialized this model.
            await model.startup()
            await model.refresh(force: false)
            await MainActor.run { scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        // iOS decides whether and when to run. Foreground/manual refresh is the
        // reliable recovery path if scheduling is denied or disabled by the user.
        do { try BGTaskScheduler.shared.submit(request) }
        catch { /* A best-effort scheduling failure never removes cached data. */ }
    }
}
