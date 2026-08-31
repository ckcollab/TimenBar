import AppKit
import SwiftUI

struct EntryRowView: View {
    @Environment(AppModel.self) private var appModel
    let entry: TimeEntry
    let presentComposer: (TimeEntry, CGPoint) -> Void
    @State private var confirmDelete = false
    @State private var pointerLocation: CGPoint?

    private var isRunning: Bool { appModel.isRunningEntry(entry) }

    var body: some View {
        HStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.projectName ?? "Unassigned")
                        .font(.headline)
                        .lineLimit(1)
                    if !entry.note.isEmpty {
                        Text(entry.note)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !entry.tags.isEmpty {
                        Text(entry.tags.map(\.name).joined(separator: " · "))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(appModel.displayDuration(for: entry).timerText)
                    .font(.title3.monospacedDigit())
            }
            .padding(.leading, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                presentComposer(entry, NSEvent.mouseLocation)
            }
            Button {
                Task {
                    if isRunning { await appModel.stopTimer(source: "entry-row-pause") }
                    else { await appModel.restartEntry(entry, source: "entry-row-play") }
                }
            } label: {
                Image(systemName: isRunning ? "pause.circle.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(isRunning ? appModel.timenTheme.accent : .primary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .help(isRunning ? "Pause this entry" : "Start this entry")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active = phase {
                pointerLocation = NSEvent.mouseLocation
            }
        }
        .contextMenu {
            if isRunning {
                Button("Edit Running Timer") {
                    presentComposer(entry, pointerLocation ?? NSEvent.mouseLocation)
                }
                Button("Pause") { Task { await appModel.stopTimer(source: "entry-context-menu-pause") } }
            } else {
                Button("Edit") {
                    presentComposer(entry, pointerLocation ?? NSEvent.mouseLocation)
                }
                Button("Start") { Task { await appModel.restartEntry(entry, source: "entry-context-menu") } }
                Divider()
                Button("Delete", role: .destructive) { confirmDelete = true }
            }
        }
        .confirmationDialog("Delete this time entry?", isPresented: $confirmDelete) {
            Button("Delete Entry", role: .destructive) { Task { await appModel.deleteEntry(entry) } }
        } message: {
            Text("The entry will be deleted from Timen and cannot be undone.")
        }
    }
}
