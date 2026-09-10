import AppKit
import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdateController {
    private let installer = SilentUpdateInstaller()
    private let controller: SPUStandardUpdaterController
    private(set) var isConfigured: Bool

    init() {
        #if DEBUG
        let configured = false
        #else
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let configured = !(publicKey ?? "").isEmpty
        #endif
        isConfigured = configured
        controller = SPUStandardUpdaterController(
            startingUpdater: configured,
            updaterDelegate: installer,
            userDriverDelegate: nil
        )
    }

    func applyAutomaticUpdates(_ enabled: Bool) {
        guard isConfigured else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
        controller.updater.automaticallyDownloadsUpdates = enabled
        if !enabled { installer.cancelPendingInstall() }
    }

    func setRelaunchPolicy(isSafeToRelaunch: @escaping @MainActor () -> Bool) {
        installer.isSafeToRelaunch = isSafeToRelaunch
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}

/// Wait until TimenBar has no interactive session, then install and relaunch.
/// Sparkle still installs on quit if that never happens.
private final class SilentUpdateInstaller: NSObject, SPUUpdaterDelegate {
    var isSafeToRelaunch: @MainActor () -> Bool = { true }

    private var pendingInstall: (() -> Void)?
    private var watchTask: Task<Void, Never>?

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        pendingInstall = immediateInstallHandler
        startWatching()
        return true
    }

    func cancelPendingInstall() {
        watchTask?.cancel()
        watchTask = nil
        pendingInstall = nil
    }

    private func startWatching() {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if isSafeToRelaunch(),
                   NSApp.modalWindow == nil,
                   !NSApp.windows.contains(where: { $0.isVisible && $0.title.localizedCaseInsensitiveContains("settings") }),
                   let install = pendingInstall
                {
                    pendingInstall = nil
                    watchTask = nil
                    install()
                    return
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}
