import AppKit
import SwiftUI

struct TimerComposerView: View {
    @Environment(AppModel.self) private var appModel

    let mode: TimerComposerMode
    @State private var draft: TimerDraft
    @State private var start: Date
    @State private var entryDate: Date
    @State private var durationText: String
    @State private var durationWasEdited = false
    @State private var hasAttemptedSubmit = false
    @State private var isProjectPopoverPresented = false
    @State private var isTagPopoverPresented = false
    @State private var isDatePickerPresented = false
    @FocusState private var focusedField: ComposerField?
    @State private var tabOrder = ComposerTabOrder()
    private let originalDuration: TimeInterval

    init(mode: TimerComposerMode) {
        self.mode = mode
        let now = Date.now
        switch mode {
        case let .new(draft, selectedDate):
            _draft = State(initialValue: draft.enforcingBillable)
            _start = State(initialValue: now)
            _entryDate = State(initialValue: selectedDate)
            _durationText = State(initialValue: TimerDurationInput.format(0))
            originalDuration = 0
        case let .running(timer):
            _draft = State(initialValue: TimerDraft(
                projectID: timer.projectID,
                tagIDs: timer.tags.map(\.id),
                note: timer.note,
                billable: true
            ))
            _start = State(initialValue: timer.startedAt)
            _entryDate = State(initialValue: timer.startedAt)
            _durationText = State(initialValue: TimerDurationInput.format(max(0, now.timeIntervalSince(timer.startedAt))))
            originalDuration = max(0, now.timeIntervalSince(timer.startedAt))
        case let .restart(_, draft):
            _draft = State(initialValue: draft.enforcingBillable)
            _start = State(initialValue: now)
            _entryDate = State(initialValue: now)
            _durationText = State(initialValue: TimerDurationInput.format(0))
            originalDuration = 0
        case let .edit(entry):
            _draft = State(initialValue: TimerDraft(
                projectID: entry.projectID,
                tagIDs: entry.tags.map(\.id),
                note: entry.note,
                billable: true
            ))
            _start = State(initialValue: entry.start)
            _entryDate = State(initialValue: entry.start)
            _durationText = State(initialValue: TimerDurationInput.format(entry.duration))
            originalDuration = entry.duration
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.bar)

            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Button { appModel.toggleFavorite(projectID: draft.projectID) } label: {
                        Image(systemName: appModel.isFavorite(projectID: draft.projectID) ? "star.fill" : "star")
                            .font(.title2)
                            .foregroundStyle(
                                appModel.isFavorite(projectID: draft.projectID)
                                    ? appModel.timenTheme.accent
                                    : .secondary
                            )
                            .frame(width: 30, height: 48)
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.projectID == nil)
                    .help(favoriteButtonHelp)
                    .accessibilityLabel(favoriteButtonHelp)

                    VStack(spacing: 0) {
                        projectTypeahead
                        Divider().padding(.horizontal, 12)
                        tagTypeahead
                    }
                    .timenCard()
                }

                HStack(alignment: .top, spacing: 12) {
                    NotesEntryField(
                        text: $draft.note,
                        tabOrder: tabOrder,
                        onTab: { focusedField = .duration }
                    )
                    .focused($focusedField, equals: .notes)
                    .padding(8)
                    .frame(minHeight: 76)
                    .overlay(alignment: .topLeading) {
                        if draft.note.isEmpty {
                            Text("Notes (optional)")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 13)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("Notes")
                    .timenCard()

                    durationEditor
                }
                .onKeyPress(.tab) {
                    focusedField = .duration
                    return tabOrder.focusDuration() ? .handled : .ignored
                }
                .onChange(of: appModel.now) { _, _ in
                    guard case .running = mode, !durationWasEdited, focusedField != .duration else { return }
                    durationText = TimerDurationInput.format(appModel.runningDisplayDuration)
                }

                if !appModel.connectivity.isOnline {
                    Label(TimenBarError.unsavedMutationMessage, systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let message = appModel.composerProjectRefreshMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if hasAttemptedSubmit, let durationValidationMessage {
                    Label(durationValidationMessage, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(18)

            Divider()
            HStack {
                if supportsDateEditing {
                    composerDateField
                } else {
                    cancelButton
                }
                Spacer()
                if supportsDateEditing { cancelButton }
                if case .running = mode {
                    Button(action: performStopAction) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!appModel.connectivity.isOnline)
                    .help("Stop the running timer")
                }
                Button(primaryTitle) { performPrimaryAction() }
                    .buttonStyle(.borderedProminent)
                    .tint(appModel.timenTheme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAttemptSubmit)
            }
            .padding(14)
            .background(.bar)
        }
        .frame(width: 520)
        .onAppear {
            if case .running = mode {
                durationText = TimerDurationInput.format(appModel.runningDisplayDuration)
            }
            if focusedField == nil {
                focusedField = .notes
            }
        }
    }

    private var durationEditor: some View {
        DurationEntryField(
            text: $durationText,
            tabOrder: tabOrder,
            showsInvalid: hasAttemptedSubmit && (
                durationForSubmission == nil || (durationWasEdited && !isRunningDurationAtLeastSavedPortion)
            ),
            onSubmit: performPrimaryAction,
            onBacktab: { focusedField = .notes },
            onUserEdit: { durationWasEdited = true }
        )
        .focused($focusedField, equals: .duration)
        .frame(width: 112)
        .frame(minHeight: 76)
        .accessibilityLabel("Duration")
        .accessibilityValue(durationText)
        .accessibilityHint("Enter hours and minutes in H:MM format, or a whole number of hours")
        .timenCard()
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) { appModel.dismissComposer() }
            .keyboardShortcut(.cancelAction)
    }

    private var composerDateField: some View {
        Button { isDatePickerPresented.toggle() } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.secondary, lineWidth: 1.5)
                        .frame(width: 30, height: 27)
                        .offset(y: 2)
                    Rectangle()
                        .fill(Color.secondary)
                        .frame(width: 28, height: 1)
                        .offset(y: -5)
                    HStack(spacing: 13) {
                        Capsule().fill(Color.secondary).frame(width: 2, height: 5)
                        Capsule().fill(Color.secondary).frame(width: 2, height: 5)
                    }
                    .offset(y: -13)
                    Text(dateDayText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.primary)
                        .offset(y: 4)
                }
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

                Text(dateMonthText)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Change entry date")
        .accessibilityLabel("Date")
        .accessibilityValue(dateAccessibilityValue)
        .accessibilityHint(dateAccessibilityHint)
        .popover(isPresented: $isDatePickerPresented, arrowEdge: .bottom) {
            DatePicker(
                "Date",
                selection: $entryDate,
                in: ...appModel.now,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .accessibilityLabel("Date")
            .padding(12)
            .environment(\.timeZone, appModel.accountCalendar.timeZone)
        }
    }

    private var dateDayText: String {
        formattedEntryDate(.dateTime.day())
    }

    private var dateMonthText: String {
        let calendar = appModel.accountCalendar
        if calendar.component(.year, from: entryDate) != calendar.component(.year, from: appModel.now) {
            return formattedEntryDate(.dateTime.month(.abbreviated).year())
        }
        return formattedEntryDate(.dateTime.month(.abbreviated))
    }

    private var dateAccessibilityValue: String {
        formattedEntryDate(
            .dateTime
                .weekday(.wide)
                .month(.wide)
                .day()
                .year()
        )
    }

    private func formattedEntryDate(_ format: Date.FormatStyle) -> String {
        var format = format
        format.timeZone = appModel.accountCalendar.timeZone
        return format.format(entryDate)
    }

    private var projectTypeahead: some View {
        Button { isProjectPopoverPresented = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedProject?.name ?? "Unassigned")
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(selectedProject?.clientName ?? "Project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if appModel.isRefreshingComposerProjects {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16)
                        .accessibilityLabel("Refreshing projects")
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Project")
        .accessibilityValue(selectedProject?.displayPath ?? "Unassigned")
        .accessibilityHint("Opens searchable project choices")
        .popover(isPresented: $isProjectPopoverPresented, arrowEdge: .bottom) {
            ProjectTypeaheadPopover(
                projects: appModel.projects,
                favoriteProjectIDs: favoriteProjectIDsForPicker,
                selectedProjectID: $draft.projectID,
                isPresented: $isProjectPopoverPresented,
                accent: appModel.timenTheme.accent
            )
        }
    }

    private var tagTypeahead: some View {
        HStack(alignment: selectedTags.isEmpty ? .center : .top, spacing: 8) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 22)
                .accessibilityHidden(true)

            if selectedTags.isEmpty {
                Button { isTagPopoverPresented = true } label: {
                    Text("Tags")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                TagChipFlow(spacing: 6) {
                    ForEach(selectedTags) { tag in
                        HStack(spacing: 4) {
                            Text(tag.name).lineLimit(1)
                            Button {
                                draft.tagIDs.removeAll { $0 == tag.id }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(3)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(tag.name)")
                        }
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.1), in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Button { isTagPopoverPresented = true } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add tags")
            .accessibilityLabel("Add tags")
            .accessibilityHint("Opens searchable tag choices")
            .popover(isPresented: $isTagPopoverPresented, arrowEdge: .bottom) {
                TagTypeaheadPopover(
                    tags: appModel.tags,
                    selectedTagIDs: $draft.tagIDs,
                    isPresented: $isTagPopoverPresented,
                    accent: appModel.timenTheme.accent
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, selectedTags.isEmpty ? 0 : 12)
        .frame(minHeight: 50)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tags")
        .accessibilityValue(selectedTags.map(\.name).joined(separator: ", "))
    }

    private var selectedProject: TimenProject? {
        appModel.projects.first { $0.id == draft.projectID }
    }

    private var selectedTags: [TimenTag] {
        draft.tagIDs.compactMap { id in appModel.tags.first { $0.id == id } }
    }

    private var favoriteButtonHelp: String {
        guard draft.projectID != nil else { return "Choose a project to favorite" }
        return appModel.isFavorite(projectID: draft.projectID) ? "Remove project favorite" : "Favorite project"
    }

    private var favoriteProjectIDsForPicker: Set<String> {
        if case .new = mode { return appModel.favoriteProjectIDs }
        return []
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
        case .new, .restart: (durationForSubmission ?? 0) > 0 ? "Save" : "Start"
        case .running, .edit: "Save"
        }
    }

    private var supportsDateEditing: Bool {
        switch mode {
        case .new, .restart, .edit: true
        case .running: false
        }
    }

    private var durationForSubmission: TimeInterval? {
        guard let parsed = TimerDurationInput.parse(durationText) else { return nil }
        if case .edit = mode, !durationWasEdited { return originalDuration }
        return parsed
    }

    private var canSubmit: Bool {
        guard canAttemptSubmit else { return false }

        switch mode {
        case .running:
            if durationWasEdited {
                return durationForSubmission != nil && isRunningDurationAtLeastSavedPortion
            }
            return true
        case .edit:
            guard !isFutureEntryDate,
                  (durationForSubmission ?? 0) > 0,
                  let interval = editedInterval
            else { return false }
            return !endsInFuture(interval)
        case .new, .restart:
            guard !isFutureEntryDate, let duration = durationForSubmission else { return false }
            if duration == 0 { return isEntryDateToday }
            guard let interval = manualInterval else { return false }
            return !endsInFuture(interval)
        }
    }

    private var canAttemptSubmit: Bool {
        appModel.connectivity.isOnline && appModel.authenticationState == .signedIn
    }

    private var manualInterval: (start: Date, end: Date)? {
        guard let duration = durationForSubmission else { return nil }
        return TimerDateChange.ending(
            at: appModel.now,
            duration: duration,
            on: entryDate,
            calendar: appModel.accountCalendar
        )
    }

    private var editedInterval: (start: Date, end: Date)? {
        guard let duration = durationForSubmission else { return nil }
        return TimerDateChange.shifting(
            start: start,
            duration: duration,
            to: entryDate,
            calendar: appModel.accountCalendar
        )
    }

    private func endsInFuture(_ interval: (start: Date, end: Date)) -> Bool {
        interval.end > appModel.now.addingTimeInterval(1)
    }

    private var isEntryDateToday: Bool {
        appModel.accountCalendar.isDate(entryDate, inSameDayAs: appModel.now)
    }

    private var isFutureEntryDate: Bool {
        let calendar = appModel.accountCalendar
        return calendar.startOfDay(for: entryDate) > calendar.startOfDay(for: appModel.now)
    }

    private var runningDurationFloor: TimeInterval {
        guard case .running = mode, let timer = appModel.runningTimer else { return 0 }
        return max(0, appModel.runningDisplayDuration - timer.elapsed(at: appModel.now))
    }

    private var isRunningDurationAtLeastSavedPortion: Bool {
        guard let duration = durationForSubmission else { return true }
        return duration + 0.5 >= runningDurationFloor
    }

    private var durationValidationMessage: String? {
        if case .running = mode {
            guard durationWasEdited else { return nil }
            guard durationForSubmission != nil else { return "Enter duration as H:MM, or a whole number of hours." }
            if !isRunningDurationAtLeastSavedPortion {
                return "Duration can’t be shorter than the time already saved on this entry."
            }
            return nil
        }
        guard supportsDateEditing else { return nil }
        guard let duration = durationForSubmission else { return "Enter duration as H:MM, or a whole number of hours." }
        if isFutureEntryDate { return "Choose today or an earlier date." }
        switch mode {
        case .edit:
            if duration == 0 { return "Duration must be greater than 0:00." }
            if let interval = editedInterval, endsInFuture(interval) {
                return "Duration extends into the future. Choose an earlier date or shorter duration."
            }
            return nil
        case .new, .restart:
            if duration == 0 && !isEntryDateToday {
                return "Enter a duration to save time on a past date."
            }
            if duration > 0, let interval = manualInterval, endsInFuture(interval) {
                return "Duration extends into the future. Choose an earlier date or shorter duration."
            }
            return nil
        default:
            return nil
        }
    }

    private var dateAccessibilityHint: String {
        switch mode {
        case .edit: "Changes the entry date while preserving its start time"
        case .new, .restart: "Sets the date for manually logged time"
        case .running: ""
        }
    }

    private func performPrimaryAction() {
        if let duration = TimerDurationInput.parse(durationText) {
            durationText = TimerDurationInput.format(duration)
        }

        guard canAttemptSubmit else { return }
        hasAttemptedSubmit = true
        guard canSubmit else { return }

        let billableDraft = draft.enforcingBillable
        switch mode {
        case .new, .restart:
            guard let duration = durationForSubmission else { return }
            if duration == 0 {
                guard isEntryDateToday else { return }
                Task { await appModel.startTimer(billableDraft, source: "timer-composer") }
            } else {
                guard let interval = manualInterval, !endsInFuture(interval) else { return }
                Task {
                    await appModel.logTime(
                        start: interval.start,
                        end: interval.end,
                        draft: billableDraft,
                        source: "timer-composer"
                    )
                }
            }
        case .running:
            appModel.updateRunningTimer(
                billableDraft,
                duration: durationWasEdited ? durationForSubmission : nil
            )
        case let .edit(entry):
            guard (durationForSubmission ?? 0) > 0,
                  let shifted = editedInterval,
                  !endsInFuture(shifted)
            else { return }
            Task {
                await appModel.updateEntry(
                    entry,
                    draft: billableDraft,
                    start: shifted.start,
                    end: shifted.end
                )
            }
        }
    }

    private func performStopAction() {
        guard canAttemptSubmit else { return }
        let billableDraft = draft.enforcingBillable
        if durationWasEdited {
            hasAttemptedSubmit = true
            guard canSubmit, let duration = durationForSubmission else { return }
            guard appModel.updateRunningTimer(billableDraft, duration: duration) else { return }
        } else {
            appModel.dismissComposer()
        }
        Task { await appModel.stopTimer(source: "running-composer-stop") }
    }
}

private enum ComposerField: Hashable {
    case notes
    case duration
}

@MainActor
private final class ComposerTabOrder {
    weak var notes: NSTextView?
    weak var duration: NSTextField?

    @discardableResult
    func focusDuration() -> Bool {
        guard let duration else { return false }
        return duration.window?.makeFirstResponder(duration) ?? false
    }

    @discardableResult
    func focusNotes() -> Bool {
        guard let notes else { return false }
        return notes.window?.makeFirstResponder(notes) ?? false
    }
}

private struct NotesEntryField: NSViewRepresentable {
    @Binding var text: String
    var tabOrder: ComposerTabOrder
    var onTab: () -> Void

    func makeNSView(context: Context) -> NotesFieldContainer {
        let container = NotesFieldContainer()
        container.textView.delegate = context.coordinator
        container.textView.string = text
        context.coordinator.textView = container.textView
        return container
    }

    func updateNSView(_ container: NotesFieldContainer, context: Context) {
        context.coordinator.parent = self
        container.textView.tabOrder = tabOrder
        container.textView.onTab = onTab
        tabOrder.notes = container.textView
        if container.textView.string != text, container.window?.firstResponder !== container.textView {
            container.textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesEntryField
        weak var textView: NSTextView?

        init(_ parent: NotesEntryField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            parent.text = textView?.string ?? parent.text
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:))
                || commandSelector == #selector(NSResponder.insertTabIgnoringFieldEditor(_:))
            {
                (textView as? NotesTextView)?.insertTab(nil)
                return true
            }
            return false
        }
    }
}

private final class NotesTextView: NSTextView {
    var onTab: (() -> Void)?
    weak var tabOrder: ComposerTabOrder?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) {
                insertBacktab(nil)
            } else {
                insertTab(nil)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func insertTab(_ sender: Any?) {
        onTab?()
        if tabOrder?.focusDuration() != true {
            window?.selectNextKeyView(self)
        }
    }

    override func insertTabIgnoringFieldEditor(_ sender: Any?) {
        insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(self)
    }
}

private final class NotesFieldContainer: NSView {
    let scrollView = NSScrollView()
    let textView = NotesTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.focusRingType = .none
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = false
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.focusRingType = .none
        textView.setAccessibilityLabel("Notes")

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let width = max(0, scrollView.contentSize.width)
        textView.minSize = NSSize(width: width, height: 0)
        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(textView) ?? false
    }
}

private struct DurationEntryField: NSViewRepresentable {
    @Binding var text: String
    var tabOrder: ComposerTabOrder
    var showsInvalid: Bool
    var onSubmit: () -> Void
    var onBacktab: () -> Void
    var onUserEdit: () -> Void

    func makeNSView(context: Context) -> DurationFieldContainer {
        let container = DurationFieldContainer()
        container.field.delegate = context.coordinator
        container.field.stringValue = text
        return container
    }

    func updateNSView(_ container: DurationFieldContainer, context: Context) {
        context.coordinator.parent = self
        tabOrder.duration = container.field
        container.field.textColor = showsInvalid ? .systemRed : .labelColor
        if container.field.currentEditor() == nil, container.field.stringValue != text {
            container.field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DurationEntryField

        init(_ parent: DurationEntryField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            parent.text = (obj.object as? NSTextField)?.stringValue ?? parent.text
            parent.onUserEdit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if let field = control as? NSTextField,
                   let duration = TimerDurationInput.parse(field.stringValue) {
                    let formatted = TimerDurationInput.format(duration)
                    field.stringValue = formatted
                    parent.text = formatted
                }
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                parent.onBacktab()
                parent.tabOrder.focusNotes()
                return true
            }
            return false
        }
    }
}

private final class DurationFieldContainer: NSView {
    let field = ZeroSelectDurationField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.placeholderString = "H:MM"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 28, weight: .regular)
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(field) ?? false
    }
}

private final class ZeroSelectDurationField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, stringValue == TimerDurationInput.format(0) {
            selectText(nil)
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if stringValue == TimerDurationInput.format(0) {
            currentEditor()?.selectAll(nil)
        }
    }
}

private struct ProjectTypeaheadPopover: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let projects: [TimenProject]
    let favoriteProjectIDs: Set<String>
    @Binding var selectedProjectID: String?
    @Binding var isPresented: Bool
    let accent: Color
    @State private var query = ""
    @State private var highlightedID: String?
    @FocusState private var searchIsFocused: Bool

    private static let unassignedID = "__timenbar_unassigned__"

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search projects or clients", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchIsFocused)
                .accessibilityLabel("Search projects or clients")
                .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                .onKeyPress(.return) { selectHighlighted(); return .handled }
                .onKeyPress(.escape) { isPresented = false; return .handled }
                .padding(12)

            Divider()

            if choices.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(choices.enumerated()), id: \.element.id) { index, choice in
                                if index == 0 || choices[index - 1].sectionTitle != choice.sectionTitle {
                                    Text(choice.sectionTitle)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.top, index == 0 ? 2 : 8)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                Button { select(choice) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: choice.systemImage)
                                            .foregroundStyle(choice.isFavorite ? accent : .secondary)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(choice.title).lineLimit(1)
                                            Text(choice.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        if choice.project?.id == selectedProjectID ||
                                            (choice.project == nil && selectedProjectID == nil)
                                        {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(accent)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .background {
                                        RoundedRectangle(cornerRadius: 7)
                                            .fill(highlightedID == choice.id ? accent.opacity(0.14) : .clear)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(choice.id)
                                .accessibilityLabel(choice.accessibilityLabel)
                                .accessibilityAddTraits(
                                    choice.project?.id == selectedProjectID ||
                                        (choice.project == nil && selectedProjectID == nil) ? .isSelected : []
                                )
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: highlightedID) { _, value in
                        guard let value else { return }
                        if reduceMotion {
                            proxy.scrollTo(value, anchor: .center)
                        } else {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(value, anchor: .center)
                            }
                        }
                    }
                }
            }

        }
        .frame(width: 350, height: 320)
        .onAppear {
            highlightedID = selectedProjectID.map { "project:\($0)" } ?? Self.unassignedID
            searchIsFocused = true
        }
        .onChange(of: query) { _, _ in highlightedID = choices.first?.id }
    }

    private var choices: [ProjectChoice] {
        var values: [ProjectChoice] = []
        if query.isEmpty || "unassigned".localizedCaseInsensitiveContains(query) {
            values.append(ProjectChoice(id: Self.unassignedID, project: nil, isFavorite: false))
        }
        let matchingProjects = projects
            .filter(\.isActive)
            .filter { project in
                query.isEmpty || project.name.localizedCaseInsensitiveContains(query) ||
                    (project.clientName?.localizedCaseInsensitiveContains(query) ?? false)
            }
        let sortedProjects = matchingProjects.sorted {
                let leftClient = $0.clientName ?? ""
                let rightClient = $1.clientName ?? ""
                let clientOrder = leftClient.localizedCaseInsensitiveCompare(rightClient)
                if clientOrder != .orderedSame { return clientOrder == .orderedAscending }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        let favorites = sortedProjects
            .filter { favoriteProjectIDs.contains($0.id) }
            .map { ProjectChoice(id: "project:\($0.id)", project: $0, isFavorite: true) }
        let remaining = sortedProjects
            .filter { !favoriteProjectIDs.contains($0.id) }
            .map { ProjectChoice(id: "project:\($0.id)", project: $0, isFavorite: false) }
        return favorites + values + remaining
    }

    private func moveHighlight(by offset: Int) {
        guard !choices.isEmpty else { return }
        let current = choices.firstIndex { $0.id == highlightedID } ?? (offset > 0 ? -1 : 0)
        let next = (current + offset + choices.count) % choices.count
        highlightedID = choices[next].id
    }

    private func selectHighlighted() {
        guard let choice = choices.first(where: { $0.id == highlightedID }) ?? choices.first else { return }
        select(choice)
    }

    private func select(_ choice: ProjectChoice) {
        selectedProjectID = choice.project?.id
        isPresented = false
    }
}

private struct ProjectChoice: Identifiable {
    let id: String
    let project: TimenProject?
    let isFavorite: Bool

    var title: String { project?.name ?? "Unassigned" }
    var subtitle: String { project?.clientName ?? (project == nil ? "No project" : "No client") }
    var accessibilityLabel: String { project?.displayPath ?? "Unassigned, no project" }
    var sectionTitle: String { isFavorite ? "Favorites" : "Projects" }
    var systemImage: String {
        if isFavorite { return "star.fill" }
        return project == nil ? "minus.circle" : "folder"
    }
}

private struct TagChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // With no width, report a single-line ideal size. With a width, wrap
        // and grow vertically so the parent can size like a token field.
        let width = proposal.width ?? 0
        if width <= 0 {
            return layout(in: .greatestFiniteMagnitude, subviews: subviews).size
        }
        return layout(in: width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = layout(in: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func layout(in width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let chipWidth = width > 0 ? min(ideal.width, width) : ideal.width
            let size = CGSize(width: chipWidth, height: ideal.height)
            if x > 0, width > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}

private struct TagTypeaheadPopover: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tags: [TimenTag]
    @Binding var selectedTagIDs: [String]
    @Binding var isPresented: Bool
    let accent: Color
    @State private var query = ""
    @State private var highlightedID: String?
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search tags", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchIsFocused)
                .accessibilityLabel("Search tags")
                .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
                .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
                .onKeyPress(.return) { toggleHighlighted(); return .handled }
                .onKeyPress(.escape) { isPresented = false; return .handled }
                .padding(12)

            Divider()

            if filteredTags.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredTags) { tag in
                                Button { toggle(tag) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: selectedTagIDs.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedTagIDs.contains(tag.id) ? accent : .secondary)
                                        Text(tag.name).lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                                    .background {
                                        RoundedRectangle(cornerRadius: 7)
                                            .fill(highlightedID == tag.id ? accent.opacity(0.14) : .clear)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(tag.id)
                                .accessibilityLabel(tag.name)
                                .accessibilityValue(selectedTagIDs.contains(tag.id) ? "Selected" : "Not selected")
                                .accessibilityAddTraits(selectedTagIDs.contains(tag.id) ? .isSelected : [])
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: highlightedID) { _, value in
                        guard let value else { return }
                        if reduceMotion {
                            proxy.scrollTo(value, anchor: .center)
                        } else {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(value, anchor: .center)
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Text("\(selectedTagIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { isPresented = false }
            }
            .padding(10)
        }
        .frame(width: 320, height: 330)
        .onAppear {
            highlightedID = filteredTags.first?.id
            searchIsFocused = true
        }
        .onChange(of: query) { _, _ in highlightedID = filteredTags.first?.id }
    }

    private var filteredTags: [TimenTag] {
        tags
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func moveHighlight(by offset: Int) {
        guard !filteredTags.isEmpty else { return }
        let current = filteredTags.firstIndex { $0.id == highlightedID } ?? (offset > 0 ? -1 : 0)
        let next = (current + offset + filteredTags.count) % filteredTags.count
        highlightedID = filteredTags[next].id
    }

    private func toggleHighlighted() {
        guard let tag = filteredTags.first(where: { $0.id == highlightedID }) ?? filteredTags.first else { return }
        toggle(tag)
    }

    private func toggle(_ tag: TimenTag) {
        if selectedTagIDs.contains(tag.id) {
            selectedTagIDs.removeAll { $0 == tag.id }
        } else {
            selectedTagIDs.append(tag.id)
        }
    }
}
