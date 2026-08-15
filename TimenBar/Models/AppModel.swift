import Foundation
import Observation
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
    var errorMessage: String?
    var composerMode: TimerComposerMode?
    var idlePrompt: IdlePromptState?
    private(set) var lastTimerDraft: TimerDraft?

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
        loadCachedState()
        startHeartbeat()
        Task { await bootstrap() }
    }

    isolated deinit { heartbeat?.cancel() }

    var statusTitle: String {
        guard settings.showElapsedInMenuBar, let runningTimer else { return "TimenBar" }
        return runningTimer.elapsed(at: now).statusTimerText
    }

    var statusBarDurationText: String {
        guard settings.showElapsedInMenuBar else { return "TimenBar" }
        if let runningTimer { return runningTimer.elapsed(at: now).timerText }
        return entries.max(by: { $0.start < $1.start })?.duration.timerText ?? "0:00"
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
        return entries.filter { interval.contains($0.start) }.sorted { $0.start > $1.start }
    }

    var weekDays: [DaySummary] {
        let calendar = accountCalendar
        let start = calendar.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? calendar.startOfDay(for: selectedDate)
        return (0 ..< 7).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let interval = dayInterval(containing: date)
            let total = entries.filter { interval.contains($0.start) }.reduce(0) { $0 + $1.duration }
            return DaySummary(date: date, duration: total, isToday: calendar.isDateInToday(date))
        }
    }

    var accountCalendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        if let identifier = account?.timeZoneIdentifier, let zone = TimeZone(identifier: identifier) { calendar.timeZone = zone }
        return calendar
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
        runningTimer = values.2
        self.entries = mergePending(remote: values.3)
        rememberMostRecentTimer(from: values.3)
        try store.replaceProjects(values.0)
        try store.replaceTags(values.1)
        try store.replaceSyncedEntries(values.3, from: week.start, to: week.end)
        configureIdleMonitor()
    }

    func selectDay(_ date: Date) { selectedDate = date }

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

    func startTimer(_ draft: TimerDraft) async {
        composerMode = nil
        lastTimerDraft = draft
        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: "lastTimerDraft")
        }
        if runningTimer != nil { await stopTimer(at: .now) }
        let localID = "local:\(UUID().uuidString)"
        let project = projects.first { $0.id == draft.projectID }
        let selectedTags = tags.filter { draft.tagIDs.contains($0.id) }
        let local = RunningTimer(
            id: localID,
            remoteID: nil,
            startedAt: .now,
            projectID: draft.projectID,
            projectName: project?.name,
            clientName: project?.clientName,
            note: draft.note,
            tags: selectedTags,
            billable: draft.billable,
            syncState: .pending
        )
        runningTimer = local
        try? store.saveSegment(PendingTimerSegment(id: UUID(), startedAt: local.startedAt, endedAt: nil, draft: draft, remoteTimerID: nil))
        configureIdleMonitor()

        if connectivity.isOnline, authenticationState == .signedIn {
            do {
                runningTimer = try await gateway.startTimer(draft)
                try? store.updateActiveSegment(remoteTimerID: runningTimer?.remoteID)
                configureIdleMonitor()
                return
            } catch { errorMessage = "The timer is running locally and will sync when Timen is reachable." }
        }
        _ = try? store.enqueue(kind: .startTimer, entryID: localID, payload: StartTimerPayload(draft: draft, requestedAt: local.startedAt))
    }

    func quickToggleTimer() async {
        guard authenticationState == .signedIn else {
            errorMessage = "Connect Timen before starting a timer."
            return
        }
        if runningTimer != nil {
            await stopTimer()
        } else if let lastTimerDraft {
            await startTimer(lastTimerDraft)
        } else {
            errorMessage = "Create a timer from the TimenBar panel first. The play button will restart it from then on."
        }
    }

    func stopTimer(at desiredEnd: Date = .now) async {
        guard let timer = runningTimer else { return }
        runningTimer = nil
        idlePrompt = nil
        idleMonitor.stop()
        let draft = TimerDraft(projectID: timer.projectID, tagIDs: timer.tags.map(\.id), note: timer.note, billable: timer.billable)
        let localEntry = TimeEntry(
            id: timer.id,
            remoteID: timer.remoteID,
            start: timer.startedAt,
            end: max(desiredEnd, timer.startedAt),
            projectID: timer.projectID,
            projectName: timer.projectName,
            clientName: timer.clientName,
            note: timer.note,
            tags: timer.tags,
            billable: timer.billable,
            syncState: .pending
        )
        entries.removeAll { $0.id == localEntry.id }
        entries.append(localEntry)
        try? store.upsertEntries([localEntry])
        _ = try? store.closeActiveSegment(at: desiredEnd)

        if connectivity.isOnline, authenticationState == .signedIn {
            do {
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
                entries.removeAll { $0.id == localEntry.id || $0.id == remote.id }
                entries.append(remote)
                try? store.deleteEntry(id: localEntry.id)
                try? store.upsertEntries([remote])
                return
            } catch { errorMessage = "The stop was saved locally and needs synchronization." }
        }

        if timer.remoteID == nil {
            try? store.cancelPendingStart(entryID: timer.id)
            _ = try? store.enqueue(
                kind: .logTime,
                entryID: localEntry.id,
                payload: LogTimePayload(localEntryID: localEntry.id, start: timer.startedAt, end: desiredEnd, draft: draft)
            )
        } else {
            _ = try? store.enqueue(kind: .stopTimer, entryID: localEntry.id, payload: StopTimerPayload(timer: timer, desiredEnd: desiredEnd))
        }
    }

    func updateRunningTimer(_ draft: TimerDraft) {
        guard var timer = runningTimer else { return }
        let project = projects.first { $0.id == draft.projectID }
        timer.projectID = draft.projectID
        timer.projectName = project?.name
        timer.clientName = project?.clientName
        timer.tags = tags.filter { draft.tagIDs.contains($0.id) }
        timer.note = draft.note
        timer.billable = draft.billable
        if timer.remoteID != nil { timer.syncState = .pending }
        runningTimer = timer
        try? store.updateActiveSegment(draft: draft)
        composerMode = nil
    }

    func trackingSettingsChanged() { configureIdleMonitor() }

    func updateEntry(_ entry: TimeEntry, draft: TimerDraft, start: Date?, end: Date?) async {
        composerMode = nil
        var local = entry
        local.projectID = draft.projectID
        if let project = projects.first(where: { $0.id == draft.projectID }) {
            local.projectName = project.name
            local.clientName = project.clientName
        }
        local.tags = tags.filter { draft.tagIDs.contains($0.id) }
        local.note = draft.note
        local.billable = draft.billable
        if let start { local.start = start }
        if let end { local.end = end }
        local.syncState = .pending
        entries.removeAll { $0.id == entry.id }
        entries.append(local)
        try? store.upsertEntries([local])
        guard let remoteID = entry.remoteID else { return }

        if connectivity.isOnline {
            do {
                let updated = try await gateway.updateEntry(id: remoteID, draft: draft, start: start, end: end)
                entries.removeAll { $0.id == entry.id || $0.id == updated.id }
                entries.append(updated)
                try? store.upsertEntries([updated])
                return
            } catch { errorMessage = "The edit was queued for synchronization." }
        }
        _ = try? store.enqueue(
            kind: .updateEntry,
            entryID: entry.id,
            payload: UpdateEntryPayload(entryID: remoteID, draft: draft, start: start, end: end, baseSummary: summary(entry))
        )
    }

    func deleteEntry(_ entry: TimeEntry) async {
        entries.removeAll { $0.id == entry.id }
        try? store.deleteEntry(id: entry.id)
        guard let remoteID = entry.remoteID else { return }
        if connectivity.isOnline {
            do { try await gateway.deleteEntry(id: remoteID); return }
            catch { errorMessage = "The deletion was queued for synchronization." }
        }
        _ = try? store.enqueue(kind: .deleteEntry, entryID: entry.id, payload: DeleteEntryPayload(entryID: remoteID, baseSummary: summary(entry)))
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
        await startTimer(draft)
    }

    func resolveIdle(_ resolution: IdleResolution) async {
        guard let prompt = idlePrompt else { return }
        switch resolution {
        case .keepAndStop:
            await stopTimer(at: .now)
        case let .removeIdleAndStop(idleStartedAt):
            await stopTimer(at: max(idleStartedAt, runningTimer?.startedAt ?? idleStartedAt))
        case .deleteEntry:
            guard let timer = runningTimer else { return }
            await stopTimer(at: .now)
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
        guard let mutations = try? store.pendingMutations() else { return }
        for mutation in mutations {
            do {
                try store.setMutation(mutation.id, state: .sending)
                try await apply(mutation)
                try store.setMutation(mutation.id, state: .applied)
            } catch {
                if await reconcile(mutation) {
                    try? store.setMutation(mutation.id, state: .applied)
                } else {
                    let conflict = SyncConflict(
                        id: UUID(),
                        mutationID: mutation.id,
                        title: "Could not verify \(mutation.kind.rawValue)",
                        explanation: "Timen may have accepted this change, but TimenBar could not prove the result without risking a duplicate.",
                        localSummary: mutation.entryID ?? mutation.kind.rawValue,
                        remoteSummary: error.localizedDescription,
                        createdAt: .now
                    )
                    try? store.addConflict(conflict)
                }
            }
        }
        try? store.removeAppliedMutations()
        conflicts = (try? store.conflicts()) ?? []
        try? await refreshAll()
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
        guard runningTimer != nil, settings.idleDetectionEnabled else { idleMonitor.stop(); return }
        idleMonitor.start(threshold: TimeInterval(settings.idleThresholdMinutes * 60)) { [weak self] idleStartedAt in
            guard let self, self.runningTimer != nil else { return }
            self.idlePrompt = IdlePromptState(idleStartedAt: idleStartedAt, showRemovalChoices: false)
            if self.settings.notificationsEnabled {
                Task { await self.notificationService.notifyIdle(minutes: self.settings.idleThresholdMinutes) }
            }
        }
    }

    private func loadCachedState() {
        projects = (try? store.projects()) ?? []
        tags = (try? store.tags()) ?? []
        favorites = (try? store.favorites()) ?? []
        conflicts = (try? store.conflicts()) ?? []
        let week = visibleWeekInterval()
        entries = (try? store.entries(from: week.start, to: week.end)) ?? []
        rememberMostRecentTimer(from: entries)
        if let segment = try? store.activeSegment() {
            let project = projects.first { $0.id == segment.draft.projectID }
            runningTimer = RunningTimer(
                id: "local:\(segment.id.uuidString)",
                remoteID: segment.remoteTimerID,
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
        accountCalendar.dateInterval(of: .weekOfYear, for: selectedDate)
            ?? DateInterval(start: accountCalendar.startOfDay(for: selectedDate), duration: 7 * 86_400)
    }

    private func dayInterval(containing date: Date) -> DateInterval {
        accountCalendar.dateInterval(of: .day, for: date)
            ?? DateInterval(start: accountCalendar.startOfDay(for: date), duration: 86_400)
    }

    private func summary(_ entry: TimeEntry) -> String {
        "\(entry.projectName ?? "Unassigned") · \(entry.duration.timerText) · \(entry.note)"
    }

    private func rememberMostRecentTimer(from entries: [TimeEntry]) {
        guard lastTimerDraft == nil, let entry = entries.max(by: { $0.start < $1.start }) else { return }
        lastTimerDraft = TimerDraft(
            projectID: entry.projectID,
            tagIDs: entry.tags.map(\.id),
            note: entry.note,
            billable: entry.billable
        )
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
