import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var appModel
    let showSettings: () -> Void
    let presentNewTimer: (CGPoint) -> Void
    let presentEntryComposer: (TimeEntry, CGPoint) -> Void
    @State private var newTimerPointerLocation: CGPoint?

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
        .overlay {
            if appModel.composerMode != nil {
                Button {
                    appModel.dismissComposer()
                } label: {
                    Color.black.opacity(0.38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close timer form")
                .accessibilityHint("Dismisses the open timer form")
            }
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
            if appModel.isLoading {
                ProgressView().controlSize(.small).tint(.white)
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

            if appModel.selectedDayEntries.isEmpty {
                ContentUnavailableView(
                    "No time for this day",
                    systemImage: "clock.badge.questionmark",
                    description: Text("Start a timer or pick another day.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(appModel.selectedDayEntries) { entry in
                            EntryRowView(entry: entry, presentComposer: presentEntryComposer)
                                .environment(appModel)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        }
    }

    private var footer: some View {
        HStack {
            Button {
                presentNewTimer(newTimerPointerLocation ?? NSEvent.mouseLocation)
            } label: {
                Label("New timer", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .onContinuousHover { phase in
                if case .active = phase {
                    newTimerPointerLocation = NSEvent.mouseLocation
                }
            }
            .disabled(appModel.authenticationState != .signedIn || !appModel.connectivity.isOnline)
            .help(appModel.connectivity.isOnline ? "Start a timer" : "An internet connection is required")

            Spacer()

            Menu {
                Button {
                    showSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }

                Divider()

                Button {
                    Task { await appModel.signOut() }
                } label: {
                    Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(appModel.authenticationState != .signedIn)

                Divider()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit TimenBar", systemImage: "power")
                }
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("TimenBar menu")
            .accessibilityLabel("TimenBar menu")
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
            if appModel.authenticationState == .signingIn {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Waiting for Timen in your browser…")
                            .font(.callout.weight(.medium))
                    }

                    HStack(spacing: 10) {
                        Button("Try Again") {
                            Task { await appModel.retrySignIn() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TimenBarTheme.accent)
                        .disabled(appModel.isAuthenticationTransitioning)
                        .help("Cancel this attempt and open a new Timen sign-in page")

                        Button("Cancel") {
                            Task { await appModel.cancelSignIn() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(appModel.isAuthenticationTransitioning)
                    }

                    Text("Try Again cancels this attempt and opens a fresh page in your default browser.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            } else {
                Button {
                    Task { await appModel.signIn() }
                } label: {
                    Text("Connect Timen").frame(width: 130)
                }
                .buttonStyle(.borderedProminent)
                .tint(TimenBarTheme.accent)
                .disabled(appModel.isAuthenticationTransitioning)

                Text("Your browser handles email, password, or Google sign-in. TimenBar never sees your password.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
