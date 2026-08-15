import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController {
    private let controller: SPUStandardUpdaterController
    private(set) var isConfigured: Bool

    init() {
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let configured = !(publicKey ?? "").isEmpty
        isConfigured = configured
        controller = SPUStandardUpdaterController(
            startingUpdater: configured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
