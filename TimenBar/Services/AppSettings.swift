import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let idleDetection = "settings.idleDetection"
        static let idleMinutes = "settings.idleMinutes"
        static let showElapsed = "settings.showElapsed"
        static let notifications = "settings.notifications"
        static let automaticUpdates = "settings.automaticUpdates"
    }

    var idleDetectionEnabled: Bool { didSet { defaults.set(idleDetectionEnabled, forKey: Key.idleDetection) } }
    var idleThresholdMinutes: Int { didSet { defaults.set(idleThresholdMinutes, forKey: Key.idleMinutes) } }
    var showElapsedInMenuBar: Bool { didSet { defaults.set(showElapsedInMenuBar, forKey: Key.showElapsed) } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Key.notifications) } }
    var automaticUpdatesEnabled: Bool { didSet { defaults.set(automaticUpdatesEnabled, forKey: Key.automaticUpdates) } }
    var startAtLoginEnabled: Bool
    var startAtLoginError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.idleDetection: true,
            Key.idleMinutes: 10,
            Key.showElapsed: true,
            Key.notifications: true,
            Key.automaticUpdates: true,
        ])
        idleDetectionEnabled = defaults.bool(forKey: Key.idleDetection)
        idleThresholdMinutes = defaults.integer(forKey: Key.idleMinutes)
        showElapsedInMenuBar = defaults.bool(forKey: Key.showElapsed)
        notificationsEnabled = defaults.bool(forKey: Key.notifications)
        automaticUpdatesEnabled = defaults.bool(forKey: Key.automaticUpdates)
        startAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setStartAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            startAtLoginEnabled = enabled
            startAtLoginError = nil
        } catch {
            startAtLoginEnabled = SMAppService.mainApp.status == .enabled
            startAtLoginError = error.localizedDescription
        }
    }
}

