import CryptoKit
import SwiftData
import XCTest
@testable import TimenBar

final class CoreBehaviorTests: XCTestCase {
    func testTimerDraftsEnforceBillableMutations() {
        XCTAssertTrue(TimerDraft.empty.billable)

        let legacyDraft = TimerDraft(projectID: "project", tagIDs: ["tag"], note: "Legacy", billable: false)
        let normalized = legacyDraft.enforcingBillable
        XCTAssertTrue(normalized.billable)
        XCTAssertEqual(normalized.projectID, legacyDraft.projectID)
        XCTAssertEqual(normalized.tagIDs, legacyDraft.tagIDs)
        XCTAssertEqual(normalized.note, legacyDraft.note)
    }

    func testChangingEntryDatePreservesStartTimeAndDuration() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 14, hour: 9, minute: 30
        )))
        let end = start.addingTimeInterval(5_400)
        let selectedDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 20, hour: 18
        )))

        let shifted = TimerDateChange.shifting(
            start: start,
            end: end,
            to: selectedDate,
            calendar: calendar
        )

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: shifted.start)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 20)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 30)
        XCTAssertEqual(shifted.end.timeIntervalSince(shifted.start), 5_400, accuracy: 0.001)
    }

    func testPKCEChallengeUsesRFC7636Base64URL() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuthSecurity.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testOAuthCallbackRequiresMatchingState() throws {
        let valid = URL(string: "http://127.0.0.1:4567/oauth/callback?code=abc&state=expected")!
        XCTAssertEqual(try OAuthSecurity.validateCallback(valid, expectedState: "expected"), "abc")

        let invalid = URL(string: "http://127.0.0.1:4567/oauth/callback?code=abc&state=attacker")!
        XCTAssertThrowsError(try OAuthSecurity.validateCallback(invalid, expectedState: "expected"))
    }

    func testTokenRefreshWindow() {
        let fresh = OAuthTokenSet(accessToken: "a", tokenType: "Bearer", expiresAt: .now.addingTimeInterval(600))
        let expiring = OAuthTokenSet(accessToken: "a", tokenType: "Bearer", expiresAt: .now.addingTimeInterval(30))
        XCTAssertFalse(fresh.needsRefresh)
        XCTAssertTrue(expiring.needsRefresh)
    }

    func testRequiredMCPToolValidation() {
        let missing = TimenToolContract.missing(from: RequiredTimenTool.names.subtracting(["timen_delete_time_entry"]))
        XCTAssertEqual(missing, ["timen_delete_time_entry"])
        XCTAssertTrue(TimenToolContract.missing(from: RequiredTimenTool.names).isEmpty)
    }

    func testIdleThresholdPromptsOnceAndRearmsAfterActivity() {
        var policy = IdlePromptPolicy(threshold: 600)
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(policy.observe(idleSeconds: 599, now: now))
        XCTAssertEqual(policy.observe(idleSeconds: 600, now: now), now.addingTimeInterval(-600))
        XCTAssertNil(policy.observe(idleSeconds: 900, now: now))
        XCTAssertNil(policy.observe(idleSeconds: 0, now: now))
        XCTAssertNotNil(policy.observe(idleSeconds: 601, now: now))
    }

    func testContinueSuppressesUntilActivity() {
        var policy = IdlePromptPolicy(threshold: 300)
        policy.suppressUntilActivity()
        XCTAssertNil(policy.observe(idleSeconds: 900, now: .now))
        XCTAssertNil(policy.observe(idleSeconds: 0, now: .now))
        XCTAssertNotNil(policy.observe(idleSeconds: 301, now: .now))
    }

    func testIdleBeforeTimerStartDoesNotImmediatelyPrompt() {
        let timerStart = Date(timeIntervalSince1970: 10_000)
        var policy = IdlePromptPolicy(threshold: 600, notBefore: timerStart)

        XCTAssertNil(policy.observe(idleSeconds: 3_600, now: timerStart))
        XCTAssertNil(policy.observe(idleSeconds: 4_199, now: timerStart.addingTimeInterval(599)))
        XCTAssertEqual(
            policy.observe(idleSeconds: 4_200, now: timerStart.addingTimeInterval(600)),
            timerStart
        )
    }

    func testDurationAcrossDaylightSavingBoundaryUsesAbsoluteTime() throws {
        let formatter = ISO8601DateFormatter()
        let start = try XCTUnwrap(formatter.date(from: "2026-03-08T01:30:00-08:00"))
        let end = try XCTUnwrap(formatter.date(from: "2026-03-08T03:30:00-07:00"))
        let entry = TimeEntry(
            id: "dst", remoteID: "dst", start: start, end: end, projectID: nil,
            projectName: nil, clientName: nil, note: "", tags: [], billable: false, syncState: .synced
        )
        XCTAssertEqual(entry.duration, 3_600)
    }

    func testTimenClockDurations() {
        XCTAssertEqual(TimenDurationParser.parseClock("4:25:48"), 15_948)
        XCTAssertEqual(TimenDurationParser.parseClock("0:30:00"), 1_800)
        XCTAssertEqual(TimenDurationParser.parseClock("4:26"), 15_960)
    }

    func testEntryDisplayOrderUsesCreationIDNotUpdatedDuration() {
        let sharedStart = Date(timeIntervalSince1970: 10_000)
        let older = TimeEntry(
            id: "100", remoteID: "100", start: sharedStart, end: sharedStart.addingTimeInterval(60),
            projectID: nil, projectName: nil, clientName: nil, note: "Older", tags: [],
            billable: false, syncState: .synced
        )
        let newer = TimeEntry(
            id: "101", remoteID: "101", start: sharedStart, end: sharedStart.addingTimeInterval(30),
            projectID: nil, projectName: nil, clientName: nil, note: "Newer", tags: [],
            billable: false, syncState: .synced
        )
        var updatedOlder = older
        updatedOlder.end = sharedStart.addingTimeInterval(10_000)

        XCTAssertEqual([updatedOlder, newer].sorted(by: TimeEntry.newestCreatedFirst).map(\.id), ["101", "100"])
    }
}

@MainActor
final class AppModelAccountIsolationTests: XCTestCase {
    func testSuccessfulAccountChangePublishesOnlyNewAccountState() async throws {
        let container = try makeContainer()
        let accountA = account(id: "account-a")
        let accountB = account(id: "account-b")
        let projectA = TimenProject(id: "shared-project", name: "Account A Project", clientName: "A")
        let projectB = TimenProject(id: "shared-project", name: "Account B Project", clientName: "B")
        let entryA = entry(id: "shared-entry", project: projectA, note: "Account A entry")
        let entryB = entry(id: "shared-entry", project: projectB, note: "Account B entry")
        let favoriteA = Favorite(
            id: UUID(), name: projectA.name, projectID: projectA.id,
            tagIDs: [], note: "", billable: true, sortOrder: 0
        )
        let store = OfflineStore(container: container)
        _ = try store.prepareForAccount(accountA)
        try store.replaceProjects([projectA])
        try store.replaceTags([TimenTag(id: "account-a-tag", name: "A Tag")])
        try store.upsertEntries([entryA])
        try store.saveFavorite(favoriteA)

        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        seedFocusedState(entryA, accountID: accountA.id, defaults: defaults)
        let gateway = AccountLifecycleGateway(
            account: accountB,
            projects: [projectB],
            tags: [TimenTag(id: "account-b-tag", name: "B Tag")],
            entries: [entryB]
        )
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)
        XCTAssertEqual(model.projects, [projectA])
        XCTAssertEqual(model.quickStartEntry?.note, entryA.note)
        model.presentNewTimer()
        XCTAssertNotNil(model.composerMode)

        await model.signIn()

        XCTAssertEqual(model.authenticationState, .signedIn)
        XCTAssertEqual(model.account, accountB)
        XCTAssertEqual(model.projects, [projectB])
        XCTAssertEqual(model.tags.map(\.id), ["account-b-tag"])
        XCTAssertEqual(model.entries, [entryB])
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertEqual(model.quickStartEntry?.note, entryB.note)
        XCTAssertEqual(defaults.string(forKey: "accountScopedStateAccountID"), accountB.id)
        XCTAssertNil(model.composerMode)

        await model.startFavorite(favoriteA)
        await model.startTimer(
            TimerDraft(projectID: projectA.id, tagIDs: [], note: "Account A draft", billable: true),
            source: "timer-composer"
        )
        let startCalls = await gateway.startTimerCallCount()
        XCTAssertEqual(startCalls, 0)
        XCTAssertEqual(try store.cachedAccount(), accountB)
        XCTAssertEqual(try store.projects(), [projectB])
        XCTAssertEqual(try store.entries(from: .distantPast, to: .distantFuture), [entryB])
    }

    func testFailedInitialRefreshDoesNotExposePreviousAccountCache() async throws {
        let container = try makeContainer()
        let accountA = account(id: "account-a")
        let accountB = account(id: "account-b")
        let projectA = TimenProject(id: "p", name: "Account A Project", clientName: "A")
        let entryA = entry(id: "entry", project: projectA, note: "Account A entry")
        let favoriteA = Favorite(
            id: UUID(), name: projectA.name, projectID: projectA.id,
            tagIDs: [], note: "", billable: true, sortOrder: 0
        )
        let store = OfflineStore(container: container)
        _ = try store.prepareForAccount(accountA)
        try store.replaceProjects([projectA])
        try store.replaceTags([TimenTag(id: "tag", name: "Account A Tag")])
        try store.upsertEntries([entryA])
        try store.saveFavorite(favoriteA)

        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        seedFocusedState(entryA, accountID: accountA.id, defaults: defaults)
        let gateway = AccountLifecycleGateway(
            account: accountB,
            projects: [],
            tags: [],
            entries: [],
            failProjects: true
        )
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        await model.signIn()

        XCTAssertEqual(model.authenticationState, .signedOut)
        XCTAssertNil(model.account)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertTrue(model.tags.isEmpty)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertNil(model.runningTimer)
        XCTAssertNil(model.focusedEntryID)
        XCTAssertNil(model.quickStartEntry)
        XCTAssertNil(model.lastTimerDraft)
        XCTAssertNil(defaults.string(forKey: "accountScopedStateAccountID"))
        XCTAssertEqual(try store.cachedAccount(), accountB)
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(try store.tags().isEmpty)
        XCTAssertTrue(try store.entries(from: .distantPast, to: .distantFuture).isEmpty)
        XCTAssertTrue(try store.favorites().isEmpty)

        await model.startFavorite(favoriteA)
        let startCalls = await gateway.startTimerCallCount()
        XCTAssertEqual(startCalls, 0)
    }

    func testLogoutClearsPersistentAndFocusedAccountState() async throws {
        let container = try makeContainer()
        let accountA = account(id: "account-a")
        let projectA = TimenProject(id: "p", name: "Account A Project", clientName: "A")
        let entryA = entry(id: "entry", project: projectA, note: "Account A entry")
        let store = OfflineStore(container: container)
        _ = try store.prepareForAccount(accountA)
        try store.replaceProjects([projectA])
        try store.upsertEntries([entryA])
        try store.saveFavorite(Favorite(
            id: UUID(), name: projectA.name, projectID: projectA.id,
            tagIDs: [], note: "", billable: true, sortOrder: 0
        ))

        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        seedFocusedState(entryA, accountID: accountA.id, defaults: defaults)
        let gateway = AccountLifecycleGateway(account: accountA, projects: [], tags: [], entries: [])
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)
        model.authenticationState = .signedIn

        await model.signOut()

        XCTAssertEqual(model.authenticationState, .signedOut)
        XCTAssertNil(model.account)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertTrue(model.favorites.isEmpty)
        XCTAssertNil(model.focusedEntryID)
        XCTAssertNil(model.quickStartEntry)
        XCTAssertNil(defaults.string(forKey: "accountScopedStateAccountID"))
        XCTAssertNil(try store.cachedAccount())
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(try store.entries(from: .distantPast, to: .distantFuture).isEmpty)
        XCTAssertTrue(try store.favorites().isEmpty)
    }

    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Schema(PersistenceSchema.models), configurations: [configuration])
    }

    private func makeModel(
        container: ModelContainer,
        gateway: AccountLifecycleGateway,
        defaults: UserDefaults
    ) -> AppModel {
        AppModel(
            container: container,
            gateway: gateway,
            settings: AppSettings(defaults: defaults),
            connectivity: ConnectivityMonitor(initiallyOnline: true, startMonitoring: false),
            defaults: defaults,
            startAutomatically: false
        )
    }

    private func makeDefaults() -> UserDefaults {
        let name = "AppModelAccountIsolationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(name, forKey: "testSuiteName")
        return defaults
    }

    private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: "testSuiteName") ?? "AppModelAccountIsolationTests"
    }

    private func seedFocusedState(_ entry: TimeEntry, accountID: String, defaults: UserDefaults) {
        defaults.set(accountID, forKey: "accountScopedStateAccountID")
        defaults.set(entry.remoteID, forKey: "focusedEntryID")
        defaults.set(try? JSONEncoder().encode(entry), forKey: "focusedEntrySnapshot")
        defaults.set(try? JSONEncoder().encode(TimerDraft(
            projectID: entry.projectID,
            tagIDs: entry.tags.map(\.id),
            note: entry.note,
            billable: true
        )), forKey: "lastTimerDraft")
    }

    private func account(id: String) -> TimenAccount {
        TimenAccount(
            id: id, name: id, email: "\(id)@example.com", teamName: "Team \(id)",
            role: "member", timeZoneIdentifier: "UTC"
        )
    }

    private func entry(id: String, project: TimenProject, note: String) -> TimeEntry {
        TimeEntry(
            id: id,
            remoteID: id,
            start: .now.addingTimeInterval(-600),
            end: .now,
            projectID: project.id,
            projectName: project.name,
            clientName: project.clientName,
            note: note,
            tags: [],
            billable: true,
            syncState: .synced
        )
    }
}

private enum AccountLifecycleGatewayError: Error {
    case projectsUnavailable
    case unsupportedMutation
}

private actor AccountLifecycleGateway: TimenGateway {
    private let currentAccount: TimenAccount
    private let projectValues: [TimenProject]
    private let tagValues: [TimenTag]
    private let entryValues: [TimeEntry]
    private let failProjects: Bool
    private var startCalls = 0

    init(
        account: TimenAccount,
        projects: [TimenProject],
        tags: [TimenTag],
        entries: [TimeEntry],
        failProjects: Bool = false
    ) {
        currentAccount = account
        projectValues = projects
        tagValues = tags
        entryValues = entries
        self.failProjects = failProjects
    }

    func startTimerCallCount() -> Int { startCalls }
    func isAuthenticated() async -> Bool { true }
    func authenticate() async throws {}
    func signOut() async throws {}
    func validateCapabilities() async throws {}
    func account() async throws -> TimenAccount { currentAccount }
    func runningTimer() async throws -> RunningTimer? { nil }
    func projects() async throws -> [TimenProject] {
        if failProjects { throw AccountLifecycleGatewayError.projectsUnavailable }
        return projectValues
    }
    func tags() async throws -> [TimenTag] { tagValues }
    func entries(from _: Date, to _: Date) async throws -> [TimeEntry] { entryValues }
    func startTimer(_ draft: TimerDraft) async throws -> RunningTimer {
        startCalls += 1
        return RunningTimer(
            id: "timer", remoteID: "timer", startedAt: .now,
            projectID: draft.projectID, projectName: nil, clientName: nil,
            note: draft.note, tags: [], billable: true, syncState: .synced
        )
    }
    func stopTimer() async throws -> TimeEntry { throw AccountLifecycleGatewayError.unsupportedMutation }
    func logTime(start _: Date, end _: Date, draft _: TimerDraft) async throws -> TimeEntry {
        throw AccountLifecycleGatewayError.unsupportedMutation
    }
    func updateEntry(
        id _: String,
        draft _: TimerDraft,
        start _: Date?,
        end _: Date?
    ) async throws -> TimeEntry {
        throw AccountLifecycleGatewayError.unsupportedMutation
    }
    func updateEntryDuration(id _: String, draft _: TimerDraft, duration _: TimeInterval) async throws -> TimeEntry {
        throw AccountLifecycleGatewayError.unsupportedMutation
    }
    func deleteEntry(id _: String) async throws { throw AccountLifecycleGatewayError.unsupportedMutation }
}
