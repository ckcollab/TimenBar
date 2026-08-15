import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = appModel

        VStack(spacing: 0) {
            header

            switch appModel.authenticationState {
            case .checking:
                ProgressView("Checking Timen…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .signedOut, .signingIn:
                SignedOutView()
            case .signedIn:
                signedInContent
            }

            footer
        }
        .frame(width: 448, height: 620)
        .background(TimenBarTheme.panel)
        .sheet(item: $model.composerMode) { mode in
            TimerComposerView(mode: mode)
                .environment(appModel)
        }
        .sheet(item: $model.idlePrompt) { prompt in
            IdlePromptView(prompt: prompt)
                .environment(appModel)
        }
        .alert("TimenBar", isPresented: Binding(
            get: { appModel.errorMessage != nil },
            set: { if !$0 { appModel.errorMessage = nil } }
        )) {
            Button("OK") { appModel.errorMessage = nil }
        } message: {
            Text(appModel.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(appModel.selectedDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.title3.weight(.semibold))
            Spacer()
            if appModel.isSyncing {
                ProgressView().controlSize(.small).tint(.white)
            } else if appModel.pendingCount > 0 {
                Label("\(appModel.pendingCount)", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            Button {
                Task { try? await appModel.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(appModel.authenticationState != .signedIn || !appModel.connectivity.isOnline)
            .help("Refresh Timen")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(height: 54)
        .background(TimenBarTheme.headerGradient)
    }

    private var signedInContent: some View {
        VStack(spacing: 0) {
            WeekStripView(
                days: appModel.weekDays,
                selectedDate: appModel.selectedDate,
                calendar: appModel.accountCalendar,
                select: { appModel.selectDay($0) },
                previousWeek: { Task { await appModel.navigateWeek(by: -1) } },
                nextWeek: { Task { await appModel.navigateWeek(by: 1) } },
                canNavigateNext: appModel.canNavigateToNextWeek,
                navigationDirection: appModel.weekNavigationDirection
            )

            Divider()

            if !appModel.favorites.isEmpty {
                FavoritesStrip()
                    .environment(appModel)
                Divider()
            }

            if appModel.selectedDayEntries.isEmpty {
                ContentUnavailableView(
                    "No time for this day",
                    systemImage: "clock.badge.questionmark",
                    description: Text("Start a timer or pick another day.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appModel.selectedDayEntries) { entry in
                            EntryRowView(entry: entry)
                                .environment(appModel)
                            Divider().padding(.leading, 18)
                        }
                    }
                }
            }

        }
    }

    private var footer: some View {
        HStack {
            Button {
                appModel.presentNewTimer()
            } label: {
                Label("New timer", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .disabled(appModel.authenticationState != .signedIn)

            Spacer()

            if !appModel.conflicts.isEmpty {
                Button {
                    openWindow(id: "conflicts")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Conflicts", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(.bar)
    }
}

private struct SignedOutView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "timer.circle.fill")
                .font(.system(size: 64))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, TimenBarTheme.accent)
            VStack(spacing: 6) {
                Text("Welcome to TimenBar")
                    .font(.title2.weight(.semibold))
                Text("Track time from your Mac menu bar using Timen’s secure OAuth connection.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 310)
            }
            Button {
                Task { await appModel.signIn() }
            } label: {
                if appModel.authenticationState == .signingIn {
                    ProgressView().controlSize(.small).frame(width: 130)
                } else {
                    Text("Connect Timen").frame(width: 130)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(TimenBarTheme.accent)
            .disabled(appModel.authenticationState == .signingIn)
            Text("Your browser handles email, password, or Google sign-in. TimenBar never sees your password.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
