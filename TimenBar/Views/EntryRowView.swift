import SwiftUI

struct EntryRowView: View {
    @Environment(AppModel.self) private var appModel
    let entry: TimeEntry
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            syncIndicator
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(entry.clientName ?? "Timen")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if entry.billable {
                        Image(systemName: "dollarsign.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                Text(entry.projectName ?? "Unassigned")
                    .font(.headline)
                    .lineLimit(1)
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !entry.tags.isEmpty {
                    Text(entry.tags.map(\.name).joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(entry.duration.timerText)
                .font(.title3.monospacedDigit())
            Button {
                appModel.presentRestart(entry)
            } label: {
                Image(systemName: "play.circle")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .help("Restart this entry")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { appModel.presentEdit(entry) }
        .contextMenu {
            Button("Edit") { appModel.presentEdit(entry) }
            Button("Restart") { appModel.presentRestart(entry) }
            Divider()
            Button("Delete", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete this time entry?", isPresented: $confirmDelete) {
            Button("Delete Entry", role: .destructive) { Task { await appModel.deleteEntry(entry) } }
        } message: {
            Text("The deletion will be synchronized with Timen and cannot be undone there.")
        }
    }

    @ViewBuilder
    private var syncIndicator: some View {
        switch entry.syncState {
        case .synced:
            Capsule().fill(TimenBarTheme.accent.opacity(0.65)).frame(width: 3, height: 42)
        case .pending, .sending:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .conflict:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .failed:
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.red)
        }
    }
}

