import SwiftUI

struct ConflictReviewView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.conflicts.isEmpty {
                ContentUnavailableView("No sync conflicts", systemImage: "checkmark.circle", description: Text("Queued changes are reconciled safely."))
            } else {
                List(appModel.conflicts) { conflict in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(conflict.title).font(.headline)
                        Text(conflict.explanation).foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 12) {
                            comparison(title: "TimenBar", text: conflict.localSummary)
                            comparison(title: "Timen", text: conflict.remoteSummary)
                        }
                        HStack {
                            Spacer()
                            Button("Keep Timen") { Task { await appModel.resolveConflict(conflict, decision: .keepTimen) } }
                            Button("Keep Local") { Task { await appModel.resolveConflict(conflict, decision: .keepLocal) } }
                                .buttonStyle(.borderedProminent)
                                .tint(TimenBarTheme.accent)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Sync Conflicts")
    }

    private func comparison(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .timenCard()
    }
}

