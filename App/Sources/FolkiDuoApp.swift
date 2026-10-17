import SwiftUI

@main
struct FolkiDuoApp: App {
    @State private var session: BudgetSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if FOLKI_DEMO
        _session = State(initialValue: DemoFixtures.makeSession())
        #else
        _session = State(initialValue: BudgetSession())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                BudgetRootView(session: session)
                    .onChange(of: context.date) { session.refresh() }
            }
            .onChange(of: scenePhase) { _, value in
                if value == .active { session.refresh() }
            }
        }
    }
}
