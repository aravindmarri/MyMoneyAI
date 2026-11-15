import SwiftUI
import SwiftData

@main
struct MyMoneyAIApp: App {
    @State private var launch: Result<AppContainer, Error>

    init() {
        _launch = State(initialValue: Result { try AppContainer.live() })
    }

    var body: some Scene {
        WindowGroup {
            switch launch {
            case .success(let container):
                LockGate { RootTabView() }
                    .environment(container)
                    .modelContainer(container.persistence.container)
            case .failure(let error):
                ContentUnavailableView {
                    Label("Unable to Open Data", systemImage: "exclamationmark.triangle")
                } description: {
                    // Never delete or reset the store automatically.
                    Text("Your data was not changed. Restart the app; if this persists, contact support.\n\n\(error.localizedDescription)")
                }
            }
        }
    }
}
