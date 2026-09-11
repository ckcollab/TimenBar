import SwiftUI

struct IdlePromptView: View {
    @Environment(AppModel.self) private var appModel
    let prompt: IdlePromptState
    @State private var showRemovalChoices: Bool

    init(prompt: IdlePromptState) {
        self.prompt = prompt
        _showRemovalChoices = State(initialValue: prompt.showRemovalChoices)
    }

    private var idleTimeText: String {
        prompt.idleDuration(at: appModel.now).compactSpokenDuration
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 46))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(appModel.timenTheme.accent)
            VStack(spacing: 6) {
                Text("You’ve been idle")
                    .font(.title2.weight(.semibold))
                Text("Idle since \(prompt.idleStartedAt.formatted(date: .omitted, time: .shortened)). What should happen to the running timer?")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if showRemovalChoices {
                VStack(spacing: 10) {
                    Button("Remove \(idleTimeText) and stop") {
                        Task { await appModel.resolveIdle(.removeIdleAndStop(idleStartedAt: prompt.idleStartedAt)) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(appModel.timenTheme.accent)
                    Button("Delete the entire entry", role: .destructive) {
                        Task { await appModel.resolveIdle(.deleteEntry) }
                    }
                    Button("Back") {
                        showRemovalChoices = false
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Button {
                        Task { await appModel.resolveIdle(.keepAndStop) }
                    } label: {
                        Label("Keep \(idleTimeText) and stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    Button("Remove \(idleTimeText)…") {
                        showRemovalChoices = true
                    }
                    Button {
                        Task { await appModel.resolveIdle(.continueWorking) }
                    } label: {
                        Label("Continue working", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
                }
            }
        }
        .padding(28)
        .frame(width: 390)
        .interactiveDismissDisabled()
    }
}
