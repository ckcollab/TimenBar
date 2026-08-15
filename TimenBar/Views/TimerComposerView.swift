import SwiftUI

struct TimerComposerView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let mode: TimerComposerMode
    @State private var draft: TimerDraft
    @State private var start: Date
    @State private var end: Date

    init(mode: TimerComposerMode) {
        self.mode = mode
        switch mode {
        case let .new(draft):
            _draft = State(initialValue: draft)
            _start = State(initialValue: .now)
            _end = State(initialValue: .now)
        case let .running(timer):
            _draft = State(initialValue: TimerDraft(projectID: timer.projectID, tagIDs: timer.tags.map(\.id), note: timer.note, billable: timer.billable))
            _start = State(initialValue: timer.startedAt)
            _end = State(initialValue: .now)
        case let .restart(_, draft):
            _draft = State(initialValue: draft)
            _start = State(initialValue: .now)
            _end = State(initialValue: .now)
        case let .edit(entry):
            _draft = State(initialValue: TimerDraft(projectID: entry.projectID, tagIDs: entry.tags.map(\.id), note: entry.note, billable: entry.billable))
            _start = State(initialValue: entry.start)
            _end = State(initialValue: entry.end ?? .now)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(.bar)

            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    Button { appModel.toggleFavorite(draft: draft) } label: {
                        Image(systemName: appModel.isFavorite(draft) ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(appModel.isFavorite(draft) ? TimenBarTheme.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(appModel.isFavorite(draft) ? "Remove favorite" : "Save favorite")

                    VStack(spacing: 0) {
                        projectPicker
                        Divider().padding(.horizontal, 12)
                        tagPicker
                    }
                    .timenCard()
                }

                HStack(alignment: .top, spacing: 12) {
                    TextEditor(text: $draft.note)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 82)
                        .overlay(alignment: .topLeading) {
                            if draft.note.isEmpty {
                                Text("Notes (optional)")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                        .timenCard()

                    Text(elapsedText)
                        .font(.system(size: 30, weight: .regular, design: .rounded).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 120)
                        .frame(minHeight: 82)
                        .timenCard()
                }

                Toggle("Billable", isOn: $draft.billable)

                if !appModel.connectivity.isOnline {
                    Label("Connect to the internet to save timer changes.", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if case .edit = mode {
                    HStack {
                        DatePicker("Start", selection: $start)
                        DatePicker("End", selection: $end)
                    }
                }
            }
            .padding(20)

            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if case .running = mode {
                    Button("Stop") {
                        dismiss()
                        Task { await appModel.stopTimer(source: "running-composer-stop") }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!appModel.connectivity.isOnline)
                }
                Button(primaryTitle) { performPrimaryAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(TimenBarTheme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        end < start || !appModel.connectivity.isOnline ||
                            appModel.authenticationState != .signedIn
                    )
            }
            .padding(14)
            .background(.bar)
        }
        .frame(width: 540)
    }

    private var projectPicker: some View {
        Picker("Project", selection: $draft.projectID) {
            Text("Unassigned").tag(String?.none)
            ForEach(groupedClients, id: \.key) { client, projects in
                Section(client) {
                    ForEach(projects) { project in Text(project.name).tag(Optional(project.id)) }
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(height: 46)
        .padding(.horizontal, 8)
        .accessibilityLabel("Project")
    }

    private var tagPicker: some View {
        Menu {
            if appModel.tags.isEmpty {
                Text("No cached tags")
            } else {
                ForEach(appModel.tags) { tag in
                    Toggle(tag.name, isOn: Binding(
                        get: { draft.tagIDs.contains(tag.id) },
                        set: { enabled in
                            if enabled { draft.tagIDs.append(tag.id) }
                            else { draft.tagIDs.removeAll { $0 == tag.id } }
                        }
                    ))
                }
            }
        } label: {
            HStack {
                Text(selectedTagNames.isEmpty ? "Tags (optional)" : selectedTagNames)
                    .foregroundStyle(selectedTagNames.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Tags")
    }

    private var groupedClients: [(key: String, value: [TimenProject])] {
        Dictionary(grouping: appModel.projects.filter(\.isActive)) { $0.clientName ?? "No client" }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    private var selectedTagNames: String {
        appModel.tags.filter { draft.tagIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
    }

    private var title: String {
        switch mode {
        case .new: "New Timer"
        case .running: "Running Timer"
        case .restart: "Restart Entry"
        case .edit: "Edit Time Entry"
        }
    }

    private var primaryTitle: String {
        switch mode {
        case .new, .restart: "Start"
        case .running, .edit: "Save"
        }
    }

    private var elapsedText: String {
        switch mode {
        case .new, .restart: "0:00"
        case .running: appModel.runningDisplayDuration.timerText
        case .edit: max(0, end.timeIntervalSince(start)).timerText
        }
    }

    private func performPrimaryAction() {
        switch mode {
        case .new, .restart:
            Task { await appModel.startTimer(draft, source: "timer-composer") }
        case .running:
            appModel.updateRunningTimer(draft)
        case let .edit(entry):
            Task { await appModel.updateEntry(entry, draft: draft, start: start, end: end) }
        }
    }
}
