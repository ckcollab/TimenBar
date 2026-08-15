import SwiftUI

struct IdlePromptView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let prompt: IdlePromptState
    @State private var showRemovalChoices: Bool

    init(prompt: IdlePromptState) {
        self.prompt = prompt
        _showRemovalChoices = State(initialValue: prompt.showRemovalChoices)
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 46))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(TimenBarTheme.accent)
            VStack(spacing: 6) {
                Text("You’ve been idle")
                    .font(.title2.weight(.semibold))
                Text("Idle since \(prompt.idleStartedAt.formatted(date: .omitted, time: .shortened)). What should happen to the running timer?")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if showRemovalChoices {
                VStack(spacing: 10) {
                    Button("Remove idle portion and stop") {
                        Task { await appModel.resolveIdle(.removeIdleAndStop(idleStartedAt: prompt.idleStartedAt)) }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TimenBarTheme.accent)
                    Button("Delete the entire entry", role: .destructive) {
                        Task { await appModel.resolveIdle(.deleteEntry) }
                        dismiss()
                    }
                    Button("Back") {
                        showRemovalChoices = false
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Button("Keep time and stop") {
                        Task { await appModel.resolveIdle(.keepAndStop) }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(TimenBarTheme.accent)
                    Button("Remove time…") {
                        showRemovalChoices = true
                    }
                    Button("Continue working") {
                        Task { await appModel.resolveIdle(.continueWorking) }
                        dismiss()
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 390)
        .interactiveDismissDisabled()
    }
}
