import Foundation
import Observation
import OSLog
import SwiftData

enum AuthenticationState: Equatable {
    case checking
    case signedOut
    case signingIn
    case signedIn
}

@MainActor
@Observable
final class AppModel {
    private let actionLogger = Logger(subsystem: "app.timenbar.TimenBar", category: "Actions")
    var authenticationState: AuthenticationState = .checking
    var account: TimenAccount?
    var projects: [TimenProject] = []
    var tags: [TimenTag] = []
    var entries: [TimeEntry] = []
    var favorites: [Favorite] = []
    var conflicts: [SyncConflict] = []
    var runningTimer: RunningTimer?
    var selectedDate = Date.now
    var now = Date.now
    var isLoading = false
    var isSyncing = false
    var weekNavigationDirection: Int?
    var errorMessage: String?
    var composerMode: TimerComposerMode?
    var idlePrompt: IdlePromptState?
    private(set) var lastTimerDraft: TimerDraft?
    private(set) var resumedEntryID: String?
    private(set) var focusedEntryID: String?
    private var focusedEntrySnapshot: TimeEntry?

    let container: ModelContainer
    let settings: AppSettings
    let connectivity: ConnectivityMonitor
    let updater: UpdateController

    private let store: OfflineStore
    private let gateway: any TimenGateway
    private let idleMonitor: IdleMonitor
    private let notificationService = NotificationService()
    private var heartbeat: Task<Void, Never>?
    private var lastKnownOnline = true

    init(
        container: ModelContainer,
        gateway: (any TimenGateway)? = nil,
        settings: AppSettings? = nil,
        connectivity: ConnectivityMonitor? = nil
    ) {
        self.container = container
        self.gateway = gateway ?? TimenMCPGateway()
        self.settings = settings ?? AppSettings()
        self.connectivity = connectivity ?? ConnectivityMonitor()
        updater = UpdateController()
        store = OfflineStore(container: container)
        idleMonitor = IdleMonitor()
        if let data = UserDefaults.standard.data(forKey: "lastTimerDraft") {
            lastTimerDraft = try? JSONDecoder().decode(TimerDraft.self, from: data)
        }
        focusedEntryID = UserDefaults.standard.string(forKey: "focusedEntryID")
        if let data = UserDefaults.standard.data(forKey: "focusedEntrySnapshot") {
            focusedEntrySnapshot = try? JSONDecoder().decode(TimeEntry.self, from: data)
        }
        loadCachedState()
        startHeartbeat()
        Task { await bootstrap() }
    }

    isolated deinit { heartbeat?.cancel() }

    var statusTitle: String {
        guard settings.showElapsedInMenuBar, let runningTimer else { return "TimenBar" }
        return runningDisplayDuration.statusTimerText
    }

    var statusBarDurationText: String {
        guard settings.showElapsedInMenuBar else { return "TimenBar" }
        if runningTimer != nil { return runningDisplayDuration.timerText }
        return quickStartEntry?.duration.timerText ?? "0:00"
    }

    var runningDisplayDuration: TimeInterval {
        guard let runningTimer else { return 0 }
        return resumedBaseEntryDuration + runningTimer.elapsed(at: now)
    }

    var isContinuingEntry: Bool { resumedEntryID != nil }

    private var resumedBaseEntryDuration: TimeInterval {
        guard let resumedEntryID else { return 0 }
        return entries.first(where: { $0.remoteID == resumedEntryID })?.duration ?? 0
    }

    var quickStartEntry: TimeEntry? {
        if let focusedEntryID,
           let focused = entries.first(where: { $0.remoteID == focusedEntryID && $0.syncState == .synced && $0.duration > 0 })
        {
            return focused
        }
        if let focusedEntrySnapshot,
           focusedEntrySnapshot.syncState == .synced,
           focusedEntrySnapshot.duration > 0
        {
            return focusedEntrySnapshot
        }
        return entries
            .filter { $0.remoteID != nil && $0.syncState == .synced && $0.duration > 0 }
            .max(by: { $0.start < $1.start })
    }

    var statusSymbol: String {
        if !conflicts.isEmpty { return "exclamationmark.triangle.fill" }
        if pendingCount > 0 { return "arrow.triangle.2.circlepath" }
        return runningTimer == nil ? "timer" : "stopwatch.fill"
    }

    var pendingCount: Int {
        (try? store.pendingMutations().count) ?? 0
    }

    var selectedDayEntries: [TimeEntry] {
        let interval = dayInterval(containing: selectedDate)
        var visible = entries.filter { interval.contains($0.start) }
        if let timer = runningTimer,
           resumedEntryID == nil,
           interval.contains(timer.startedAt),
           !visible.contains(where: { $0.remoteID == timer.remoteID || $0.id == timer.id })
        {
            visible.append(TimeEntry(
                id: timer.id,
                remoteID: timer.remoteID,
                start: timer.startedAt,
                end: nil,
                projectID: timer.projectID,
                projectName: timer.projectName,
                clientName: timer.clientName,
                note: timer.note,
                tags: timer.tags,
                billable: timer.billable,
                syncState: timer.syncState
            ))
        }
        return visible.sorted(by: TimeEntry.newestCreatedFirst)
    }

    func isRunningEntry(_ entry: TimeEntry) -> Bool {
        guard let runningTimer else { return false }
        if let resumedEntryID { return entry.remoteID == resumedEntryID }
        return entry.id == runningTimer.id || entry.remoteID == runningTimer.remoteID
    }

    func displayDuration(for entry: TimeEntry) -> TimeInterval {
        isRunningEntry(entry) ? runningDisplayDuration : entry.duration
    }

    var weekDays: [DaySummary] {
        let calendar = accountCalendar
        let start = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? calendar.startOfDay(for: selectedDate)
        return (0 ..< 7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let interval = dayInterval(containing: date)
            var total = entries.filter { interval.contains($0.start) }.reduce(0) { $0 + $1.duration }
            if let resumedEntryID,
               let resumed = entries.first(where: { $0.remoteID == resumedEntryID }),
               interval.contains(resumed.start), let runningTimer
            {
                total += runningTimer.elapsed(at: now)
            }
            return DaySummary(date: date, duration: total, isToday: calendar.isDateInToday(date))
        }
    }

    var accountCalendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        if let identifier = account?.timeZoneIdentifier, let zone = TimeZone(identifier: identifier) { calendar.timeZone = zone }
        return calendar
    }

    var canNavigateToNextWeek: Bool {
        guard let displayedWeek = accountCalendar.dateInterval(of: .weekOfYear, for: selectedDate),
              let currentWeek = accountCalendar.dateInterval(of: .weekOfYear, for: .now)
        else { return false }
        return displayedWeek.start < currentWeek.start
    }

    func signIn() async {
        guard authenticationState != .signingIn else { return }
        authenticationState = .signingIn
        errorMessage = nil
        do {
            try await gateway.authenticate()
            authenticationState = .signedIn
            try await refreshAll()
        } catch {
            authenticationState = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        do { try await gateway.signOut() }
        catch { errorMessage = error.localizedDescription }
        authenticationState = .signedOut
        account = nil
        runningTimer = nil
        resumedEntryID = nil
        try? store.discardActiveSegment()
        idleMonitor.stop()
    }

    func refreshAll() async throws {
        guard connectivity.isOnline else { return }
        isLoading = true
        defer { isLoading = false }
        let account = try await gateway.account()
        self.account = account
        async let projects = gateway.projects()
        async let tags = gateway.tags()
        async let timer = gateway.runningTimer()
        let week = visibleWeekInterval()
        async let entries = gateway.entries(from: week.start, to: week.end)
        let values = try await (projects, tags, timer, entries)
        self.projects = values.0
        self.tags = values.1
        let localContinuation = resumedEntryID == nil ? nil : runningTimer
        if let remoteTimer = values.2 {
            if resumedEntryID != nil {
                errorMessage = "A timer was started in Timen while a TimenBar continuation was active. Timen’s running timer is now authoritative."
                resumedEntryID = nil
                try? store.discardActiveSegment()
            }
            runningTimer = remoteTimer
        } else {
            runningTimer = localContinuation
        }
        self.entries = mergePending(remote: values.3)
        rememberMostRecentTimer(from: values.3)
        try store.replaceProjects(values.0)
        try store.replaceTags(values.1)
        try store.replaceSyncedEntries(values.3, from: week.start, to: week.end)
        configureIdleMonitor()
    }

    func selectDay(_ date: Date) { selectedDate = date }

    func navigateWeek(by offset: Int) async {
        guard weekNavigationDirection == nil,
              offset != 0,
              let destination = accountCalendar.date(byAdding: .weekOfYear, value: offset, to: selectedDate)
        else { return }
        weekNavigationDirection = offset < 0 ? -1 : 1
        defer { weekNavigationDirection = nil }
        await loadWeek(containing: destination)
    }

    func presentNewTimer() { composerMode = .new(.empty) }

    func presentRunningTimer() {
        guard let timer = runningTimer else { return }
        composerMode = .running(timer)
    }

    func presentRestart(_ entry: TimeEntry) {
        composerMode = .restart(
            entry,
            TimerDraft(projectID: entry.projectID, tagIDs: entry.tags.map(\.id), note: entry.note, billable: entry.billable)
        )
    }

    func presentEdit(_ entry: TimeEntry) { composerMode = .edit(entry) }

    func restartEntry(_ entry: TimeEntry, source: String = "entry") async {
        actionLogger.debug("restart-entry source=\(source, privacy: .public) entry=\(entry.remoteID ?? entry.id, privacy: .public)")
        guard let remoteID = entry.remoteID, entry.syncState == .synced else {
            errorMessage = "Only synchronized Timen entries can be restarted."
            return
        }
        guard authenticationState == .signedIn, connectivity.isOnline else {
            errorMessage = "TimenBar must be online and connected to continue an entry."
            return
        }
        if runningTimer != nil {
            await stopTimer(at: .now, source: "replace-running:\(source)")
            guard runningTimer == nil else { return }
        }
        let draft = TimerDraft(
            projectID: entry.projectID,
            tagIDs: entry.tags.map(\.id),
            note: entry.note,
            billable: entry.billable
        )
        let startedAt = Date.now
        focus(on: remoteID)
        resumedEntryID = remoteID
        runningTimer = RunningTimer(
            id: "continuation:\(remoteID)",
            remoteID: nil,
            startedAt: startedAt,
            projectID: entry.projectID,
            projectName: entry.projectName,
            clientName: entry.clientName,
            note: entry.note,
            tags: entry.tags,
            billable: entry.billable,
            syncState: .synced
        )
        lastTimerDraft = draft
        composerMode = nil
        try? store.discardActiveSegment()
        try? store.saveSegment(PendingTimerSegment(
            id: UUID(),
            startedAt: startedAt,
            endedAt: nil,
            draft: draft,
            remoteTimerID: "resume:\(remoteID)"
        ))
        configureIdleMonitor()
    }

    func startTimer(_ draft: TimerDraft, source: String = "composer") async {
        actionLogger.debug("start-timer source=\(source, privacy: .public) project=\(draft.projectID ?? "unassigned", privacy: .public)")
        guard authenticationState == .signedIn, connectivity.isOnline else {
            errorMessage = "TimenBar must be online and connected to start a timer."
            return
        }
        if runningTimer != nil {
            await stopTimer(at: .now, source: "replace-running:\(source)")
            guard runningTimer == nil else { return }
        }
        do {
            let remote = try await gateway.startTimer(draft)
            if let remoteID = remote.remoteID { focus(on: remoteID) }
            resumedEntryID = nil
            runningTimer = remote
            lastTimerDraft = draft
            if let data = try? JSONEncoder().encode(draft) {
                UserDefaults.standard.set(data, forKey: "lastTimerDraft")
            }
            composerMode = nil
            try? store.discardActiveSegment()
            try? store.saveSegment(PendingTimerSegment(
                id: UUID(), startedAt: remote.startedAt, endedAt: nil,
                draft: draft, remoteTimerID: remote.remoteID
            ))
            configureIdleMonitor()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func quickToggleTimer(source: String = "status-bar") async {
        actionLogger.debug("quick-toggle source=\(source, privacy: .public) running=\(self.runningTimer != nil, privacy: .public)")
        guard authenticationState == .signedIn, connectivity.isOnline else {
            errorMessage = "TimenBar must be online and connected to change timers."
            return
        }
        if runningTimer != nil {
            await stopTimer(source: "quick-toggle:\(source)")
        } else if let quickStartEntry {
            await restartEntry(quickStartEntry, source: source)
        } else {
            errorMessage = "There is no synchronized time entry to restart. Open TimenBar to create one."
        }
    }

    func stopTimer(at desiredEnd: Date = .now, source: String = "unspecified") async {
        actionLogger.debug("stop-timer source=\(source, privacy: .public) timer=\(self.runningTimer?.remoteID ?? "none", privacy: .public)")
        guard let timer = runningTimer else { return }
        guard authenticationState == .signedIn, connectivity.isOnline else {
            errorMessage = "TimenBar must be online and connected to stop a timer."
            return
        }
        idlePrompt = nil
        idleMonitor.stop()
        let draft = TimerDraft(projectID: timer.projectID, tagIDs: timer.tags.map(\.id), note: timer.note, billable: timer.billable)
        do {
            if let resumedEntryID,
               let original = entries.first(where: { $0.remoteID == resumedEntryID })
            {
                let addedDuration = max(0, desiredEnd.timeIntervalSince(timer.startedAt))
                let updated = try await gateway.updateEntryDuration(
                    id: resumedEntryID,
                    draft: draft,
                    duration: original.duration + addedDuration
                )
                runningTimer = nil
                self.resumedEntryID = nil
                idlePrompt = nil
                idleMonitor.stop()
                try? store.discardActiveSegment()
                entries.removeAll { $0.id == original.id || $0.remoteID == resumedEntryID }
                entries.append(updated)
                if let updatedID = updated.remoteID { focus(on: updatedID) }
                try? store.deleteEntry(id: original.id)
                try? store.upsertEntries([updated])
                return
            }
            var remote = try await gateway.stopTimer()
            let timingChanged = abs(desiredEnd.timeIntervalSince(.now)) > 2
            let metadataChanged = remote.projectID != draft.projectID ||
                Set(remote.tags.map(\.id)) != Set(draft.tagIDs) ||
                remote.note != draft.note || remote.billable != draft.billable
            if (timingChanged || metadataChanged), let id = remote.remoteID {
                remote = try await gateway.updateEntry(
                    id: id,
                    draft: draft,
                    start: timingChanged ? timer.startedAt : nil,
                    end: timingChanged ? desiredEnd : nil
                )
            }
            runningTimer = nil
            resumedEntryID = nil
            idlePrompt = nil
            idleMonitor.stop()
            _ = try? store.closeActiveSegment(at: desiredEnd)
            entries.removeAll { $0.id == timer.id || $0.remoteID == remote.remoteID }
            entries.append(remote)
            if let remoteID = remote.remoteID { focus(on: remoteID) }
            try? store.deleteEntry(id: timer.id)
            try? store.upsertEntries([remote])
        } catch {
            errorMessage = error.localizedDescription
            configureIdleMonitor()
        }
    }

    func updateRunningTimer(_ draft: TimerDraft) {
        guard connectivity.isOnline else {
            errorMessage = "TimenBar must be online to edit a running timer."
            return
        }
        guard var timer = runningTimer else { return }
        let project = projects.first { $0.id == draft.projectID }
        timer.projectID = draft.projectID
        timer.projectName = project?.name
        timer.clientName = project?.clientName
        timer.tags = tags.filter { draft.tagIDs.contains($0.id) }
        timer.note = draft.note
        timer.billable = draft.billable
        runningTimer = timer
        try? store.updateActiveSegment(draft: draft)
        composerMode = nil
    }

    func trackingSettingsChanged() { configureIdleMonitor() }

    func updateEntry(_ entry: TimeEntry, draft: TimerDraft, start: Date?, end: Date?) async {
        guard authenticationState == .signedIn, connectivity.isOnline else {
            errorMessage = "TimenBar must be online and connected to edit entries."
            return
        }
        guard let remoteID = entry.remoteID else {
            errorMessage = "This local entry cannot be edited because offline syncing is disabled."
            return
        }
        do {
            let updated = try await gateway.updateEntry(id: remoteID, draft: draft, start: start, end: end)
            composerMode = nil
            entries.removeAll { $0.id == entry.id || $0.id == updated.id }
            entries.append(updated)
            if let remoteID = updated.remoteID { focus(on: remoteID) }
            try? store.upsertEntries([updated])
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteEntry(_ entry: TimeEntry) async {
        guard authenticationState == .signedIn, connectivity.isOnline else {
            errorMessage = "TimenBar must be online and connected to delete entries."
            return
        }
        guard let remoteID = entry.remoteID else {
            try? store.discardLocalEntryAndMutations(entryID: entry.id)
            entries.removeAll { $0.id == entry.id }
            return
        }
        do {
            try await gateway.deleteEntry(id: remoteID)
            entries.removeAll { $0.id == entry.id }
            if focusedEntryID == remoteID {
                focusedEntryID = nil
                focusedEntrySnapshot = nil
                UserDefaults.standard.removeObject(forKey: "focusedEntryID")
                UserDefaults.standard.removeObject(forKey: "focusedEntrySnapshot")
            }
            try? store.deleteEntry(id: entry.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func toggleFavorite(draft: TimerDraft) {
        if let existing = favorites.first(where: { favoriteMatches($0, draft: draft) }) {
            favorites.removeAll { $0.id == existing.id }
            try? store.deleteFavorite(id: existing.id)
        } else {
            let projectName = projects.first { $0.id == draft.projectID }?.name ?? "Unassigned"
            let favorite = Favorite(
                id: UUID(),
                name: draft.note.isEmpty ? projectName : draft.note,
                projectID: draft.projectID,
                tagIDs: draft.tagIDs,
                note: draft.note,
                billable: draft.billable,
                sortOrder: favorites.count
            )
            favorites.append(favorite)
            try? store.saveFavorite(favorite)
        }
    }

    func isFavorite(_ draft: TimerDraft) -> Bool { favorites.contains { favoriteMatches($0, draft: draft) } }

    func startFavorite(_ favorite: Favorite) async {
        let draft = TimerDraft(projectID: favorite.projectID, tagIDs: favorite.tagIDs, note: favorite.note, billable: favorite.billable)
        await startTimer(draft, source: "favorite")
    }

    func resolveIdle(_ resolution: IdleResolution) async {
        guard let prompt = idlePrompt else { return }
        switch resolution {
        case .keepAndStop:
            await stopTimer(at: .now, source: "idle-keep-and-stop")
        case let .removeIdleAndStop(idleStartedAt):
            await stopTimer(at: max(idleStartedAt, runningTimer?.startedAt ?? idleStartedAt), source: "idle-remove-and-stop")
        case .deleteEntry:
            guard let timer = runningTimer else { return }
            await stopTimer(at: .now, source: "idle-delete-entry")
            if let entry = entries.first(where: { $0.id == timer.id || $0.remoteID == timer.remoteID }) { await deleteEntry(entry) }
        case .continueWorking:
            idleMonitor.suppressUntilActivity()
            idlePrompt = nil
        }
        if resolution.isTerminal { idlePrompt = nil }
        _ = prompt
    }

    func syncNow() async {
        guard connectivity.isOnline, authenticationState == .signedIn, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do { try await refreshAll() }
        catch { errorMessage = error.localizedDescription }
    }

    func resolveConflict(_ conflict: SyncConflict, decision: ConflictDecision) async {
        guard let mutation = try? store.mutation(id: conflict.mutationID) else {
            try? store.resolveConflict(id: conflict.id)
            conflicts = (try? store.conflicts()) ?? []
            return
        }
        do {
            switch decision {
            case .keepLocal: try await apply(mutation)
            case .keepTimen: break
            }
            try store.setMutation(mutation.id, state: .applied)
            try store.resolveConflict(id: conflict.id)
            try store.removeAppliedMutations()
            conflicts = try store.conflicts()
            try await refreshAll()
        } catch { errorMessage = error.localizedDescription }
    }

    private func bootstrap() async {
        if await gateway.isAuthenticated() {
            authenticationState = .signedIn
            if connectivity.isOnline {
                do { try await gateway.validateCapabilities(); try await refreshAll() }
                catch { errorMessage = error.localizedDescription }
            }
        } else {
            authenticationState = .signedOut
        }
    }

    private func startHeartbeat() {
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                now = .now
                if connectivity.isOnline, !lastKnownOnline { await syncNow() }
                lastKnownOnline = connectivity.isOnline
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func configureIdleMonitor() {
        guard let runningTimer, settings.idleDetectionEnabled else { idleMonitor.stop(); return }
        idleMonitor.start(
            threshold: TimeInterval(settings.idleThresholdMinutes * 60),
            notBefore: runningTimer.startedAt
        ) { [weak self] idleStartedAt in
            guard let self, self.runningTimer != nil else { return }
            self.idlePrompt = IdlePromptState(idleStartedAt: idleStartedAt, showRemovalChoices: false)
            if self.settings.notificationsEnabled {
                Task { await self.notificationService.notifyIdle(minutes: self.settings.idleThresholdMinutes) }
            }
        }
    }

    private func loadCachedState() {
        try? store.discardAllQueuedWork()
        projects = (try? store.projects()) ?? []
        tags = (try? store.tags()) ?? []
        favorites = (try? store.favorites()) ?? []
        conflicts = (try? store.conflicts()) ?? []
        let week = visibleWeekInterval()
        entries = (try? store.entries(from: week.start, to: week.end)) ?? []
        if let focusedEntryID,
           let focused = entries.first(where: { $0.remoteID == focusedEntryID })
        {
            focusedEntrySnapshot = focused
        }
        let accidentalEntries = entries.filter {
            guard $0.remoteID == nil, $0.syncState == .pending, $0.end != nil, $0.duration < 60 else { return false }
            let candidate = $0
            return entries.contains {
                $0.remoteID != nil && $0.projectID == candidate.projectID && $0.note == candidate.note &&
                    accountCalendar.isDate($0.start, inSameDayAs: candidate.start)
            }
        }
        for entry in accidentalEntries { try? store.discardLocalEntryAndMutations(entryID: entry.id) }
        entries.removeAll { entry in accidentalEntries.contains(where: { $0.id == entry.id }) }
        rememberMostRecentTimer(from: entries)
        if let segment = try? store.activeSegment() {
            let continuationID = segment.remoteTimerID?.hasPrefix("resume:") == true
                ? String(segment.remoteTimerID!.dropFirst("resume:".count))
                : nil
            resumedEntryID = continuationID
            let project = projects.first { $0.id == segment.draft.projectID }
            runningTimer = RunningTimer(
                id: "local:\(segment.id.uuidString)",
                remoteID: continuationID == nil ? segment.remoteTimerID : nil,
                startedAt: segment.startedAt,
                projectID: segment.draft.projectID,
                projectName: project?.name,
                clientName: project?.clientName,
                note: segment.draft.note,
                tags: tags.filter { segment.draft.tagIDs.contains($0.id) },
                billable: segment.draft.billable,
                syncState: .pending
            )
        }
    }

    private func apply(_ mutation: QueuedMutation) async throws {
        let decoder = JSONDecoder()
        switch mutation.kind {
        case .startTimer:
            let payload = try decoder.decode(StartTimerPayload.self, from: mutation.payload)
            if let running = try await gateway.runningTimer(), abs(running.startedAt.timeIntervalSince(payload.requestedAt)) < 120 {
                runningTimer = running
                try? store.updateActiveSegment(remoteTimerID: running.remoteID)
                return
            }
            if payload.requestedAt.timeIntervalSinceNow < -120 {
                _ = try await gateway.logTime(start: payload.requestedAt, end: .now, draft: payload.draft)
            }
            runningTimer = try await gateway.startTimer(payload.draft)
            if let runningTimer {
                _ = try? store.closeActiveSegment(at: runningTimer.startedAt)
                try? store.saveSegment(PendingTimerSegment(
                    id: UUID(),
                    startedAt: runningTimer.startedAt,
                    endedAt: nil,
                    draft: payload.draft,
                    remoteTimerID: runningTimer.remoteID
                ))
            }
        case .stopTimer:
            let payload = try decoder.decode(StopTimerPayload.self, from: mutation.payload)
            var entry = try await gateway.stopTimer()
            if let id = entry.remoteID {
                let draft = TimerDraft(projectID: payload.timer.projectID, tagIDs: payload.timer.tags.map(\.id), note: payload.timer.note, billable: payload.timer.billable)
                entry = try await gateway.updateEntry(id: id, draft: draft, start: payload.timer.startedAt, end: payload.desiredEnd)
            }
            try store.upsertEntries([entry])
        case .logTime:
            let payload = try decoder.decode(LogTimePayload.self, from: mutation.payload)
            let entry = try await gateway.logTime(start: payload.start, end: payload.end, draft: payload.draft)
            try store.deleteEntry(id: payload.localEntryID)
            try store.upsertEntries([entry])
        case .updateEntry:
            let payload = try decoder.decode(UpdateEntryPayload.self, from: mutation.payload)
            let entry = try await gateway.updateEntry(id: payload.entryID, draft: payload.draft, start: payload.start, end: payload.end)
            try store.upsertEntries([entry])
        case .deleteEntry:
            let payload = try decoder.decode(DeleteEntryPayload.self, from: mutation.payload)
            try await gateway.deleteEntry(id: payload.entryID)
        }
    }

    private func reconcile(_ mutation: QueuedMutation) async -> Bool {
        let decoder = JSONDecoder()
        do {
            switch mutation.kind {
            case .startTimer:
                let payload = try decoder.decode(StartTimerPayload.self, from: mutation.payload)
                guard let timer = try await gateway.runningTimer() else { return false }
                return abs(timer.startedAt.timeIntervalSince(payload.requestedAt)) < 120 && timer.projectID == payload.draft.projectID
            case .logTime:
                let payload = try decoder.decode(LogTimePayload.self, from: mutation.payload)
                let matches = try await gateway.entries(from: payload.start.addingTimeInterval(-60), to: payload.end.addingTimeInterval(60))
                return matches.contains { abs($0.start.timeIntervalSince(payload.start)) < 2 && abs(($0.end ?? .distantFuture).timeIntervalSince(payload.end)) < 2 && $0.projectID == payload.draft.projectID }
            case .stopTimer:
                return try await gateway.runningTimer() == nil
            case .updateEntry:
                let payload = try decoder.decode(UpdateEntryPayload.self, from: mutation.payload)
                let interval = visibleWeekInterval()
                return try await gateway.entries(from: interval.start, to: interval.end).contains { $0.remoteID == payload.entryID && $0.note == payload.draft.note }
            case .deleteEntry:
                let payload = try decoder.decode(DeleteEntryPayload.self, from: mutation.payload)
                let interval = visibleWeekInterval()
                return try await !gateway.entries(from: interval.start, to: interval.end).contains { $0.remoteID == payload.entryID }
            }
        } catch { return false }
    }

    private func favoriteMatches(_ favorite: Favorite, draft: TimerDraft) -> Bool {
        favorite.projectID == draft.projectID && Set(favorite.tagIDs) == Set(draft.tagIDs) && favorite.note == draft.note && favorite.billable == draft.billable
    }

    private func mergePending(remote: [TimeEntry]) -> [TimeEntry] {
        let pending = entries.filter { $0.syncState != .synced }
        let remoteIDs = Set(remote.compactMap(\.remoteID))
        return remote + pending.filter { $0.remoteID.map { !remoteIDs.contains($0) } ?? true }
    }

    private func visibleWeekInterval() -> DateInterval {
        weekInterval(containing: selectedDate)
    }

    private func weekInterval(containing date: Date) -> DateInterval {
        accountCalendar.dateInterval(of: .weekOfYear, for: date)
            ?? DateInterval(start: accountCalendar.startOfDay(for: date), duration: 7 * 86_400)
    }

    private func dayInterval(containing date: Date) -> DateInterval {
        accountCalendar.dateInterval(of: .day, for: date)
            ?? DateInterval(start: accountCalendar.startOfDay(for: date), duration: 86_400)
    }

    private func summary(_ entry: TimeEntry) -> String {
        "\(entry.projectName ?? "Unassigned") · \(entry.duration.timerText) · \(entry.note)"
    }

    private func isPermanentServerError(_ error: Error) -> Bool {
        guard let error = error as? TimenBarError else { return false }
        return switch error {
        case .networkUnavailable: false
        case .notAuthenticated, .incompatibleServer, .invalidResponse, .oauth, .conflict: true
        }
    }

    private func rememberMostRecentTimer(from entries: [TimeEntry]) {
        guard let entry = entries.max(by: { $0.start < $1.start }) else { return }
        if focusedEntryID == nil {
            focus(on: entry.remoteID)
        } else if entries.contains(where: { $0.remoteID == focusedEntryID }) {
            focus(on: focusedEntryID)
        }
        if lastTimerDraft == nil {
            lastTimerDraft = TimerDraft(
                projectID: entry.projectID,
                tagIDs: entry.tags.map(\.id),
                note: entry.note,
                billable: entry.billable
            )
        }
    }

    private func focus(on remoteID: String?) {
        guard let remoteID else { return }
        focusedEntryID = remoteID
        UserDefaults.standard.set(remoteID, forKey: "focusedEntryID")
        if let entry = entries.first(where: { $0.remoteID == remoteID }) {
            focusedEntrySnapshot = entry
            if let data = try? JSONEncoder().encode(entry) {
                UserDefaults.standard.set(data, forKey: "focusedEntrySnapshot")
            }
        }
    }

    private func loadWeek(containing destination: Date) async {
        let week = weekInterval(containing: destination)
        guard authenticationState == .signedIn, connectivity.isOnline else {
            let cached = (try? store.entries(from: week.start, to: week.end)) ?? []
            selectedDate = destination
            entries = cached
            return
        }
        do {
            let remote = try await gateway.entries(from: week.start, to: week.end)
            selectedDate = destination
            entries = mergePending(remote: remote)
            try store.replaceSyncedEntries(remote, from: week.start, to: week.end)
            rememberMostRecentTimer(from: remote)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum TimerComposerMode: Identifiable {
    case new(TimerDraft)
    case running(RunningTimer)
    case restart(TimeEntry, TimerDraft)
    case edit(TimeEntry)

    var id: String {
        switch self {
        case .new: "new"
        case .running: "running"
        case let .restart(entry, _): "restart-\(entry.id)"
        case let .edit(entry): "edit-\(entry.id)"
        }
    }
}

struct IdlePromptState: Identifiable {
    let id = UUID()
    var idleStartedAt: Date
    var showRemovalChoices: Bool
}

private extension IdleResolution {
    var isTerminal: Bool {
        switch self {
        case .continueWorking: false
        default: true
        }
    }
}
