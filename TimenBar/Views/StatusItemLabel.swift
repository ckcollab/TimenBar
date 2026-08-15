import SwiftUI

struct StatusItemLabel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Label(appModel.statusTitle, systemImage: appModel.statusSymbol)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let timer = appModel.runningTimer {
            return "TimenBar running for \(timer.elapsed(at: appModel.now).timerText)"
        }
        return "TimenBar, no timer running"
    }
}

