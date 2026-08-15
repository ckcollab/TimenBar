import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var settings = appModel.settings

        TabView {
            Form {
                Section("Account") {
                    if let account = appModel.account {
                        LabeledContent("Name", value: account.name)
                        LabeledContent("Team", value: account.teamName)
                        LabeledContent("Time zone", value: account.timeZoneIdentifier)
                        Button("Disconnect Timen", role: .destructive) { Task { await appModel.signOut() } }
                    } else {
                        Text("Not connected to Timen").foregroundStyle(.secondary)
                    }
                }
                Section("Startup") {
                    Toggle("Start TimenBar at login", isOn: Binding(
                        get: { settings.startAtLoginEnabled },
                        set: { settings.setStartAtLogin($0) }
                    ))
                    if let error = settings.startAtLoginError { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .padding(20)
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Toggle("Detect inactivity while a timer runs", isOn: $settings.idleDetectionEnabled)
                Stepper("Prompt after \(settings.idleThresholdMinutes) minutes", value: $settings.idleThresholdMinutes, in: 5 ... 60, step: 5)
                    .disabled(!settings.idleDetectionEnabled)
                Toggle("Show idle notifications", isOn: $settings.notificationsEnabled)
                Toggle("Show elapsed time in the menu bar", isOn: $settings.showElapsedInMenuBar)
            }
            .padding(20)
            .tabItem { Label("Tracking", systemImage: "stopwatch") }

            Form {
                LabeledContent("Connection", value: appModel.connectivity.isOnline ? "Online" : "Offline")
                LabeledContent("Queued actions", value: "\(appModel.pendingCount)")
                LabeledContent("Conflicts", value: "\(appModel.conflicts.count)")
                HStack {
                    Button("Sync Now") { Task { await appModel.syncNow() } }
                        .disabled(!appModel.connectivity.isOnline || appModel.authenticationState != .signedIn)
                    Button("Review Conflicts") {
                        openWindow(id: "conflicts")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    .disabled(appModel.conflicts.isEmpty)
                }
            }
            .padding(20)
            .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }

            Form {
                Toggle("Automatically check for updates", isOn: $settings.automaticUpdatesEnabled)
                    .disabled(!appModel.updater.isConfigured)
                Button("Check for Updates…") { appModel.updater.checkForUpdates() }
                    .disabled(!appModel.updater.isConfigured)
                if !appModel.updater.isConfigured {
                    Text("Set SUPublicEDKey and the appcast URL for signed public builds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("About") {
                    Text("TimenBar is an unofficial, open-source client and is not affiliated with Timen.")
                    Link("TimenBar source code", destination: URL(string: "https://github.com/timenbar/timenbar")!)
                    Text("MIT License")
                }
            }
            .padding(20)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 580, height: 420)
        .onChange(of: settings.idleDetectionEnabled) { _, _ in appModel.trackingSettingsChanged() }
        .onChange(of: settings.idleThresholdMinutes) { _, _ in appModel.trackingSettingsChanged() }
        .onChange(of: settings.automaticUpdatesEnabled) { _, enabled in
            if appModel.updater.isConfigured { appModel.updater.automaticallyChecksForUpdates = enabled }
        }
    }
}
