import SwiftData
import SwiftUI

@main
struct TimenBarApp: App {
    private let container: ModelContainer
    private let statusBarController: StatusBarController
    @State private var appModel: AppModel

    init() {
        do {
            let container = try ModelContainer(for: Schema(PersistenceSchema.models))
            let model = AppModel(container: container)
            self.container = container
            statusBarController = StatusBarController(appModel: model, container: container)
            _appModel = State(initialValue: model)
        } catch {
            fatalError("Unable to initialize TimenBar storage: \(error)")
        }
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appModel)
                .modelContainer(container)
        }

        Window("Sync Conflicts", id: "conflicts") {
            ConflictReviewView()
                .environment(appModel)
                .modelContainer(container)
        }
        .defaultSize(width: 720, height: 480)
    }
}
