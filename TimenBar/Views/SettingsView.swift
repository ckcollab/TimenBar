import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.settings

        TabView {
            settingsPage {
                SettingsCard(title: "Account", systemImage: "person.crop.circle") {
                    if let account = appModel.account {
                        VStack(alignment: .leading, spacing: 10) {
                            SettingsValueRow(label: "Name", value: account.name)
                            SettingsValueRow(label: "Team", value: account.teamName)
                            SettingsValueRow(label: "Time zone", value: account.timeZoneIdentifier)
                            SettingsValueRow(label: "Theme", value: account.effectiveTheme.displayName)
                            Divider()
                            Button("Disconnect Timen", role: .destructive) {
                                Task { await appModel.signOut() }
                            }
                        }
                    } else {
                        Label("Not connected to Timen", systemImage: "person.crop.circle.badge.xmark")
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsCard(title: "Startup", systemImage: "power") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Start on login", isOn: Binding(
                            get: { settings.startAtLoginEnabled },
                            set: { settings.setStartAtLogin($0) }
                        ))
                        .toggleStyle(.checkbox)
                        Text("Open TimenBar automatically when you sign in to your Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let error = settings.startAtLoginError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .tabItem { Label("General", systemImage: "gear") }

            settingsPage {
                SettingsCard(title: "Timer", systemImage: "stopwatch") {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Show elapsed time in the menu bar", isOn: $settings.showElapsedInMenuBar)
                            .toggleStyle(.checkbox)
                        Divider()
                        Toggle("Detect inactivity while a timer runs", isOn: $settings.idleDetectionEnabled)
                            .toggleStyle(.checkbox)
                        Stepper(
                            "Prompt after \(settings.idleThresholdMinutes) minutes",
                            value: $settings.idleThresholdMinutes,
                            in: 5 ... 60,
                            step: 5
                        )
                        .disabled(!settings.idleDetectionEnabled)
                        Toggle("Show idle notifications", isOn: $settings.notificationsEnabled)
                            .toggleStyle(.checkbox)
                            .disabled(!settings.idleDetectionEnabled)
                    }
                }
            }
            .tabItem { Label("Tracking", systemImage: "stopwatch") }

            settingsPage {
                SettingsCard(title: "Updates", systemImage: "arrow.down.circle") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Automatically check for updates", isOn: $settings.automaticUpdatesEnabled)
                            .toggleStyle(.checkbox)
                            .disabled(!appModel.updater.isConfigured)
                        Button("Check for Updates…") { appModel.updater.checkForUpdates() }
                            .disabled(!appModel.updater.isConfigured)
                        if !appModel.updater.isConfigured {
                            Text("Update checks are unavailable in this build.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                SettingsCard(title: "About TimenBar", systemImage: "info.circle") {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "timer.circle.fill")
                            .font(.system(size: 38))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(appModel.timenTheme.accent)

                        VStack(alignment: .leading, spacing: 7) {
                            Text("TimenBar")
                                .font(.title3.weight(.semibold))
                            Text("An unofficial, open-source Timen client for macOS.")
                                .foregroundStyle(.secondary)

                            HStack(spacing: 4) {
                                Text("Made by Eric Carmichael at Ckc —")
                                Link("ckcollab.com", destination: URL(string: "https://ckcollab.com")!)
                            }

                            HStack(spacing: 14) {
                                Link(
                                    "Source code",
                                    destination: URL(string: "https://github.com/timenbar/timenbar")!
                                )
                                Text("MIT License")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 400, idealHeight: 460)
        .onChange(of: settings.idleDetectionEnabled) { _, _ in appModel.trackingSettingsChanged() }
        .onChange(of: settings.idleThresholdMinutes) { _, _ in appModel.trackingSettingsChanged() }
        .onChange(of: settings.automaticUpdatesEnabled) { _, enabled in
            if appModel.updater.isConfigured { appModel.updater.automaticallyChecksForUpdates = enabled }
        }
    }

    private func settingsPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
        .background(TimenBarTheme.panel)
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Divider()
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .timenCard()
    }
}

private struct SettingsValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
