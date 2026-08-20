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
    private enum DefaultsKey {
        static let accountID = "accountScopedStateAccountID"
        static let lastTimerDraft = "lastTimerDraft"
        static let focusedEntryID = "focusedEntryID"
        static let focusedEntrySnapshot = "focusedEntrySnapshot"
    }

    private let actionLogger = Logger(subsystem: "app.timenbar.TimenBar", category: "Actions")
    var authenticationState: AuthenticationState = .checking
    var account: TimenAccount?
    var projects: [TimenProject] = []
    var tags: [TimenTag] = []
    var entries: [TimeEntry] = []
    var favorites: [Favorite] = []
    var runningTimer: RunningTimer?
    var selectedDate = Date.now
    var now = Date.now
    var isLoading = false
    var weekNavigationDirection: Int?
    var errorMessage: String?
    var composerMode: TimerComposerMode? {
        didSet {
            if composerMode == nil { composerAccountID = nil }
        }
    }
    var idlePrompt: IdlePromptState?
    private(set) var lastTimerDraft: TimerDraft?
    private(set) var resumedEntryID: String?
    private(set) var focusedEntryID: String?
    private var focusedEntrySnapshot: TimeEntry?
    private var composerAccountID: String?

    let container: ModelContainer
    let settings: AppSettings
    let connectivity: ConnectivityMonitor
    let updater: UpdateController

    private let store: OfflineStore
    private let gateway: any TimenGateway
    private let defaults: UserDefaults
    private let idleMonitor: IdleMonitor
    private let notificationService = NotificationService()
    private var heartbeat: Task<Void, Never>?
    private var lastKnownOnline = true

    init(
        container: ModelContainer,
        gateway: (any TimenGateway)? = nil,
        settings: AppSettings? = nil,
        connectivity: ConnectivityMonitor? = nil,
        defaults: UserDefaults = .standard,
        startAutomatically: Bool = true
    ) {
        self.container = container
        self.gateway = gateway ?? TimenMCPGateway()
        self.settings = settings ?? AppSettings()
        self.connectivity = connectivity ?? ConnectivityMonitor()
        self.defaults = defaults
        updater = UpdateController()
        store = OfflineStore(container: container)
        idleMonitor = IdleMonitor()
        loadCachedState()
        if startAutomatically {
            startHeartbeat()
            Task { await bootstrap() }
        }
    }

    isolated deinit { heartbeat?.cancel() }

    var statusTitle: String {
        guard settings.showElapsedInMenuBar, runningTimer != nil else { return "TimenBar" }
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
           let focused = entries.first(where: { $0.remoteID == focusedEntryID && $0.duration > 0 })
        {
            return focused
        }
        if let focusedEntrySnapshot,
           focusedEntrySnapshot.duration > 0
        {
            return focusedEntrySnapshot
        }
        return entries
            .filter { $0.remoteID != nil && $0.duration > 0 }
            .max(by: { $0.start < $1.start })
    }

    var statusSymbol: String {
        return runningTimer == nil ? "timer" : "stopwatch.fill"
    }

    var favoriteProjectIDs: Set<String> {
        Set(favorites.compactMap(\.projectID))
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
            try await refreshAll()
            authenticationState = .signedIn
        } catch {
            authenticationState = .signedOut
            clearVisibleAccountState()
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        // Revoke local mutation authority before the first suspension point so
        // a click queued behind Logout cannot submit Account A state.
        authenticationState = .signedOut
        var signOutError: Error?
        do { try store.clearAccountData() }
        catch { signOutError = signOutError ?? error }
        clearAccountScopedDefaults()
        clearVisibleAccountState()
        do { try await gateway.signOut() }
        catch { signOutError = signOutError ?? error }
        errorMessage = signOutError?.localizedDescription
    }

    func refreshAll() async throws {
        guard connectivity.isOnline else { throw TimenBarError.networkUnavailable }
        isLoading = true
        defer { isLoading = false }
        let remoteAccount = try await gateway.account()
        let transition = try store.prepareForAccount(remoteAccount)
        if transition != .unchanged {
            clearAccountScopedDefaults()
            clearVisibleAccountState()
        } else if account == nil {
            loadAccountScopedDefaults(for: remoteAccount.id)
        }
        account = remoteAccount
        async let projects = gateway.projects()
        async let tags = gateway.tags()
        async let timer = gateway.runningTimer()
        let week = visibleWeekInterval()
        async let entries = gateway.entries(from: week.start, to: week.end)
        let values = try await (projects, tags, timer, entries)
        guard account?.id == remoteAccount.id,
              try store.cachedAccount()?.id == remoteAccount.id
        else { return }

        try store.replaceProjects(values.0)
        try store.replaceTags(values.1)
        try store.replaceEntries(values.3, from: week.start, to: week.end)
        let refreshedFavorites = try store.reconcileFavorites(with: values.0)

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
        self.projects = values.0
        self.tags = values.1
        self.entries = values.3
        favorites = refreshedFavorites
        rememberMostRecentTimer(from: values.3)
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

    func presentNewTimer() {
        guard let accountID = account?.id else { return }
        composerAccountID = accountID
        composerMode = .new(.empty)
    }

    func presentRunningTimer() {
        guard let timer = runningTimer, let accountID = account?.id else { return }
        composerAccountID = accountID
        composerMode = .running(timer)
    }

    func presentRestart(_ entry: TimeEntry) {
        guard isCurrentEntry(entry) else {
            errorMessage = "That entry no longer belongs to the active Timen account."
            return
        }
        composerAccountID = account?.id
        composerMode = .restart(
            entry,
            TimerDraft(projectID: entry.projectID, tagIDs: entry.tags.map(\.id), note: entry.note, billable: true)
        )
    }

    func presentEdit(_ entry: TimeEntry) {
        guard isCurrentEntry(entry) else {
            errorMessage = "That entry no longer belongs to the active Timen account."
            return
        }
        composerAccountID = account?.id
        composerMode = .edit(entry)
    }

    func restartEntry(_ entry: TimeEntry, source: String = "entry") async {
        actionLogger.debug("restart-entry source=\(source, privacy: .public) entry=\(entry.remoteID ?? entry.id, privacy: .public)")
        guard isCurrentEntry(entry) else {
            errorMessage = "That entry no longer belongs to the active Timen account."
            return
        }
        guard let remoteID = entry.remoteID else {
            errorMessage = "Only Timen entries can be restarted."
            return
        }
        guard authenticationState == .signedIn, connectivity.isOnline else {
            errorMessage = "TimenBar must be online and connected to continue an entry."
            return
        }
        guard let mutationAccountID = account?.id else { return }
        if runningTimer != nil {
            await stopTimer(at: .now, source: "replace-running:\(source)")
            guard isMutationContextCurrent(mutationAccountID), runningTimer == nil else { return }
        }
        let draft = TimerDraft(
            projectID: entry.projectID,
            tagIDs: entry.tags.map(\.id),
            note: entry.note,
            billable: true
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
            billable: true,
            syncState: .synced
        )
        lastTimerDraft = draft
        persistLastTimerDraft()
        composerMode = nil
        try? store.discardActiveSegment()
        try? store.saveSegment(ActiveTimerSegment(
            id: UUID(),
            startedAt: startedAt,
            endedAt: nil,
            draft: draft,
            remoteTimerID: "resume:\(remoteID)"
        ))
        configureIdleMonitor()
    }

    func startTimer(_ draft: TimerDraft, source: String = "composer") async {
        let draft = draft.enforcingBillable
        actionLogger.debug("start-timer source=\(source, privacy: .public) project=\(draft.projectID ?? "unassigned", privacy: .public)")
        guard authenticationState == .signedIn, connectivity.isOnline else {
            errorMessage = "TimenBar must be online and connected to start a timer."
            return
        }
        guard let mutationAccountID = account?.id else { return }
        if source == "timer-composer" {
            guard composerAccountID == mutationAccountID, composerMode != nil else {
                errorMessage = "That timer form belongs to a previous Timen account."
                return
            }
        }
        guard validateDraftReferences(draft) else { return }
        if runningTimer != nil {
            await stopTimer(at: .now, source: "replace-running:\(source)")
            guard isMutationContextCurrent(mutationAccountID), runningTimer == nil else { return }
        }
        do {
            let remote = try await gateway.startTimer(draft)
            guard isMutationContextCurrent(mutationAccountID) else { return }
            if let remoteID = remote.remoteID { focus(on: remoteID) }
            resumedEntryID = nil
            runningTimer = remote
            lastTimerDraft = draft
            persistLastTimerDraft()
            composerMode = nil
            try? store.discardActiveSegment()
            try? store.saveSegment(ActiveTimerSegment(
                id: UUID(), startedAt: remote.startedAt, endedAt: nil,
                draft: draft, remoteTimerID: remote.remoteID
            ))
            configureIdleMonitor()
        } catch {
            guard isMutationContextCurrent(mutationAccountID) else { return }
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
        guard let mutationAccountID = account?.id else { return }
        idlePrompt = nil
        idleMonitor.stop()
        let draft = TimerDraft(projectID: timer.projectID, tagIDs: timer.tags.map(\.id), note: timer.note, billable: true)
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
                guard isMutationContextCurrent(mutationAccountID) else { return }
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
            guard isMutationContextCurrent(mutationAccountID) else { return }
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
                guard isMutationContextCurrent(mutationAccountID) else { return }
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
            guard isMutationContextCurrent(mutationAccountID) else { return }
            errorMessage = error.localizedDescription
            configureIdleMonitor()
        }
    }

    func updateRunningTimer(_ draft: TimerDraft) {
        let draft = draft.enforcingBillable
        guard connectivity.isOnline else {
            errorMessage = "TimenBar must be online to edit a running timer."
            return
        }
        guard var timer = runningTimer else { return }
        guard let accountID = account?.id,
              composerAccountID == accountID,
              composerMode != nil
        else {
            errorMessage = "That timer form belongs to a previous Timen account."
            return
        }
        guard validateDraftReferences(draft) else { return }
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
        let draft = draft.enforcingBillable
        guard authenticationState == .signedIn, connectivity.isOnline else {
            errorMessage = "TimenBar must be online and connected to edit entries."
            return
        }
        guard let mutationAccountID = account?.id else { return }
        guard composerAccountID == mutationAccountID, composerMode != nil else {
            errorMessage = "That timer form belongs to a previous Timen account."
            return
        }
        guard isCurrentEntry(entry) else {
            errorMessage = "That entry no longer belongs to the active Timen account."
            return
        }
        guard validateDraftReferences(draft) else { return }
        guard let remoteID = entry.remoteID else {
            errorMessage = "Only entries already saved in Timen can be edited."
            return
        }
        do {
            let updated = try await gateway.updateEntry(id: remoteID, draft: draft, start: start, end: end)
            guard isMutationContextCurrent(mutationAccountID) else { return }
            composerMode = nil
            entries.removeAll { $0.id == entry.id || $0.id == updated.id }
            entries.append(updated)
            if let remoteID = updated.remoteID { focus(on: remoteID) }
            try? store.upsertEntries([updated])
        } catch {
            guard isMutationContextCurrent(mutationAccountID) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func deleteEntry(_ entry: TimeEntry) async {
        guard authenticationState == .signedIn, connectivity.isOnline else {
            errorMessage = "TimenBar must be online and connected to delete entries."
            return
        }
        guard let mutationAccountID = account?.id else { return }
        guard isCurrentEntry(entry) else {
            errorMessage = "That entry no longer belongs to the active Timen account."
            return
        }
        guard let remoteID = entry.remoteID else {
            errorMessage = "Only entries already saved in Timen can be deleted."
            return
        }
        do {
            try await gateway.deleteEntry(id: remoteID)
            guard isMutationContextCurrent(mutationAccountID) else { return }
            entries.removeAll { $0.id == entry.id }
            if focusedEntryID == remoteID {
                focusedEntryID = nil
                focusedEntrySnapshot = nil
                defaults.removeObject(forKey: DefaultsKey.focusedEntryID)
                defaults.removeObject(forKey: DefaultsKey.focusedEntrySnapshot)
            }
            try? store.deleteEntry(id: entry.id)
        } catch {
            guard isMutationContextCurrent(mutationAccountID) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func toggleFavorite(projectID: String?) {
        guard let accountID = account?.id,
              composerAccountID == accountID,
              composerMode != nil
        else {
            errorMessage = "That timer form belongs to a previous Timen account."
            return
        }
        guard let projectID, let project = projects.first(where: { $0.id == projectID }) else { return }
        let existing = favorites.filter { $0.projectID == projectID }
        if !existing.isEmpty {
            favorites.removeAll { $0.projectID == projectID }
            existing.forEach { try? store.deleteFavorite(id: $0.id) }
        } else {
            let favorite = Favorite(
                id: UUID(),
                name: project.name,
                projectID: projectID,
                tagIDs: [],
                note: "",
                billable: true,
                sortOrder: favorites.count
            )
            favorites.append(favorite)
            try? store.saveFavorite(favorite)
        }
    }

    func isFavorite(projectID: String?) -> Bool {
        guard let projectID else { return false }
        return favorites.contains { $0.projectID == projectID }
    }

    func startFavorite(_ favorite: Favorite) async {
        guard favorites.contains(favorite),
              let projectID = favorite.projectID,
              projects.contains(where: { $0.id == projectID })
        else {
            errorMessage = "That favorite no longer belongs to the active Timen account."
            return
        }
        let draft = TimerDraft(projectID: favorite.projectID, tagIDs: [], note: "", billable: true)
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

    private func bootstrap() async {
        guard await gateway.isAuthenticated() else {
            try? store.clearAccountData()
            clearAccountScopedDefaults()
            clearVisibleAccountState()
            authenticationState = .signedOut
            return
        }

        if !connectivity.isOnline {
            if account != nil {
                authenticationState = .signedIn
            } else {
                clearVisibleAccountState()
                authenticationState = .signedOut
                errorMessage = "Connect to Timen once before using the offline read cache."
            }
            return
        }

        do {
            try await gateway.validateCapabilities()
            try await refreshAll()
            authenticationState = .signedIn
        } catch {
            clearVisibleAccountState()
            authenticationState = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    private func startHeartbeat() {
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                now = .now
                if connectivity.isOnline, !lastKnownOnline, authenticationState == .signedIn {
                    do { try await refreshAll() }
                    catch { errorMessage = error.localizedDescription }
                }
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

    private func isCurrentEntry(_ entry: TimeEntry) -> Bool {
        entries.contains(entry)
    }

    private func isMutationContextCurrent(_ accountID: String) -> Bool {
        authenticationState == .signedIn && account?.id == accountID
    }

    private func validateDraftReferences(_ draft: TimerDraft) -> Bool {
        if let projectID = draft.projectID,
           !projects.contains(where: { $0.id == projectID })
        {
            errorMessage = "The selected project is not available for the active Timen account."
            return false
        }
        let availableTagIDs = Set(tags.map(\.id))
        guard Set(draft.tagIDs).isSubset(of: availableTagIDs) else {
            errorMessage = "One or more selected tags are not available for the active Timen account."
            return false
        }
        return true
    }

    private func loadCachedState() {
        let migrationKey = "didDiscardLegacyOfflineMutationState"
        if !defaults.bool(forKey: migrationKey) {
            do {
                try store.discardLegacyOfflineMutationState()
                defaults.set(true, forKey: migrationKey)
            } catch {
                actionLogger.error("legacy offline-state cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let cachedAccount = try? store.cachedAccount()
        guard let cachedAccount else {
            // Legacy caches did not record an owner. They are unsafe to expose
            // or reuse because remote IDs are only meaningful within an account.
            try? store.clearAccountData()
            clearAccountScopedDefaults()
            clearVisibleAccountState()
            return
        }
        account = cachedAccount
        loadAccountScopedDefaults(for: cachedAccount.id)
        projects = (try? store.projects()) ?? []
        tags = (try? store.tags()) ?? []
        favorites = (try? store.reconcileFavorites(with: projects)) ?? []
        let week = visibleWeekInterval()
        entries = (try? store.entries(from: week.start, to: week.end)) ?? []
        if let focusedEntryID,
           let focused = entries.first(where: { $0.remoteID == focusedEntryID })
        {
            focusedEntrySnapshot = focused
        }
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
                syncState: .synced
            )
        }
    }

    private func loadAccountScopedDefaults(for accountID: String) {
        guard defaults.string(forKey: DefaultsKey.accountID) == accountID else {
            clearAccountScopedDefaults()
            return
        }
        if let data = defaults.data(forKey: DefaultsKey.lastTimerDraft) {
            lastTimerDraft = try? JSONDecoder().decode(TimerDraft.self, from: data)
        }
        focusedEntryID = defaults.string(forKey: DefaultsKey.focusedEntryID)
        if let data = defaults.data(forKey: DefaultsKey.focusedEntrySnapshot) {
            focusedEntrySnapshot = try? JSONDecoder().decode(TimeEntry.self, from: data)
        }
    }

    private func clearAccountScopedDefaults() {
        defaults.removeObject(forKey: DefaultsKey.accountID)
        defaults.removeObject(forKey: DefaultsKey.lastTimerDraft)
        defaults.removeObject(forKey: DefaultsKey.focusedEntryID)
        defaults.removeObject(forKey: DefaultsKey.focusedEntrySnapshot)
    }

    private func claimAccountScopedDefaults() -> Bool {
        guard let accountID = account?.id else { return false }
        if defaults.string(forKey: DefaultsKey.accountID) != accountID {
            clearAccountScopedDefaults()
            defaults.set(accountID, forKey: DefaultsKey.accountID)
        }
        return true
    }

    private func clearVisibleAccountState() {
        account = nil
        projects = []
        tags = []
        entries = []
        favorites = []
        runningTimer = nil
        resumedEntryID = nil
        focusedEntryID = nil
        focusedEntrySnapshot = nil
        lastTimerDraft = nil
        composerAccountID = nil
        composerMode = nil
        idlePrompt = nil
        idleMonitor.stop()
    }

    private func persistLastTimerDraft() {
        guard claimAccountScopedDefaults(), let lastTimerDraft,
              let data = try? JSONEncoder().encode(lastTimerDraft)
        else { return }
        defaults.set(data, forKey: DefaultsKey.lastTimerDraft)
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
            persistLastTimerDraft()
        }
    }

    private func focus(on remoteID: String?) {
        guard let remoteID, claimAccountScopedDefaults() else { return }
        focusedEntryID = remoteID
        defaults.set(remoteID, forKey: DefaultsKey.focusedEntryID)
        if let entry = entries.first(where: { $0.remoteID == remoteID }) {
            focusedEntrySnapshot = entry
            if let data = try? JSONEncoder().encode(entry) {
                defaults.set(data, forKey: DefaultsKey.focusedEntrySnapshot)
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
        guard let requestAccountID = account?.id else { return }
        do {
            let remote = try await gateway.entries(from: week.start, to: week.end)
            guard authenticationState == .signedIn, account?.id == requestAccountID else { return }
            selectedDate = destination
            entries = remote
            try store.replaceEntries(remote, from: week.start, to: week.end)
            rememberMostRecentTimer(from: remote)
        } catch {
            guard authenticationState == .signedIn, account?.id == requestAccountID else { return }
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
