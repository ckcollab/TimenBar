import CryptoKit
import SwiftData
import XCTest
@testable import TimenBar

final class CoreBehaviorTests: XCTestCase {
    func testDurationInputParsesHoursAndMinutes() {
        XCTAssertEqual(TimerDurationInput.parse("0:00"), 0)
        XCTAssertEqual(TimerDurationInput.parse("1:30"), 5_400)
        XCTAssertEqual(TimerDurationInput.parse(" 12:05 "), 43_500)
        XCTAssertEqual(TimerDurationInput.parse("1:5"), 3_900)
        XCTAssertNil(TimerDurationInput.parse("90"))
        XCTAssertNil(TimerDurationInput.parse("1:60"))
        XCTAssertNil(TimerDurationInput.parse("-1:30"))
        XCTAssertNil(TimerDurationInput.parse("hours"))
    }

    func testManualEntryEndsAtCurrentClockTimeOnSelectedDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let currentTime = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 21, hour: 10, minute: 15
        )))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 20, hour: 18, minute: 45
        )))

        let interval = TimerDateChange.ending(
            at: currentTime,
            duration: 5_400,
            on: yesterday,
            calendar: calendar
        )

        let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: interval.start)
        let endComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: interval.end)
        XCTAssertEqual(startComponents.year, 2026)
        XCTAssertEqual(startComponents.month, 8)
        XCTAssertEqual(startComponents.day, 20)
        XCTAssertEqual(startComponents.hour, 8)
        XCTAssertEqual(startComponents.minute, 45)
        XCTAssertEqual(endComponents.year, 2026)
        XCTAssertEqual(endComponents.month, 8)
        XCTAssertEqual(endComponents.day, 20)
        XCTAssertEqual(endComponents.hour, 10)
        XCTAssertEqual(endComponents.minute, 15)
        XCTAssertEqual(interval.end.timeIntervalSince(interval.start), 5_400, accuracy: 0.001)
    }

    func testManualEntryKeepsSelectedStartDateWhenDurationCrossesMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let currentTime = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 21, hour: 1
        )))
        let selectedDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 20
        )))

        let interval = TimerDateChange.ending(
            at: currentTime,
            duration: 7_200,
            on: selectedDate,
            calendar: calendar
        )

        XCTAssertTrue(calendar.isDate(interval.start, inSameDayAs: selectedDate))
        XCTAssertEqual(calendar.component(.hour, from: interval.start), 0)
        XCTAssertEqual(calendar.component(.hour, from: interval.end), 2)
        XCTAssertEqual(interval.end.timeIntervalSince(interval.start), 7_200, accuracy: 0.001)
    }

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

    func testChangingEntryDateAppliesEditedDurationFromOriginalStartTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let originalStart = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 14, hour: 9, minute: 30
        )))
        let selectedDate = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 20
        )))

        let shifted = TimerDateChange.shifting(
            start: originalStart,
            duration: 7_200,
            to: selectedDate,
            calendar: calendar
        )

        let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: shifted.start)
        XCTAssertEqual(startComponents.day, 20)
        XCTAssertEqual(startComponents.hour, 9)
        XCTAssertEqual(startComponents.minute, 30)
        XCTAssertEqual(shifted.end.timeIntervalSince(shifted.start), 7_200, accuracy: 0.001)
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
    func testAccountThemeDrivesAppTheme() async throws {
        let container = try makeContainer()
        var activeAccount = account(id: "account")
        activeAccount.theme = .purple
        let gateway = AccountLifecycleGateway(
            account: activeAccount,
            projects: [],
            tags: [],
            entries: []
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        XCTAssertEqual(model.timenTheme, .standard)

        await model.signIn()

        XCTAssertEqual(model.timenTheme, .purple)
    }

    func testNewTimerUsesTheSelectedDayAsItsInitialDate() async throws {
        let container = try makeContainer()
        let activeAccount = account(id: "account")
        let gateway = AccountLifecycleGateway(
            account: activeAccount,
            projects: [],
            tags: [],
            entries: []
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        await model.signIn()
        let selectedDate = Date(timeIntervalSince1970: 1_700_000_000)
        model.selectDay(selectedDate)

        model.presentNewTimer()

        guard case let .new(_, composerDate)? = model.composerMode else {
            return XCTFail("Expected a new timer form")
        }
        XCTAssertEqual(composerDate, selectedDate)
    }

    func testOpeningComposerRefreshesProjectsAndPersistsLatestCatalog() async throws {
        let container = try makeContainer()
        let activeAccount = account(id: "account")
        let original = TimenProject(id: "original", name: "Original", clientName: "Client")
        let added = TimenProject(id: "added", name: "New Assignment", clientName: "Client")
        let gateway = AccountLifecycleGateway(
            account: activeAccount,
            projects: [original],
            tags: [],
            entries: []
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        await model.signIn()
        let initialProjectRequests = await gateway.projectRequestCount()
        XCTAssertEqual(initialProjectRequests, 1)
        await gateway.setProjects([original, added])

        model.presentNewTimer()
        XCTAssertTrue(model.isRefreshingComposerProjects)
        await waitForComposerProjectRefresh(model)

        let refreshedProjectRequests = await gateway.projectRequestCount()
        XCTAssertEqual(refreshedProjectRequests, 2)
        XCTAssertEqual(Set(model.projects.map(\.id)), Set([original.id, added.id]))
        XCTAssertNil(model.composerProjectRefreshMessage)
        let cachedProjects = try OfflineStore(container: container).projects()
        XCTAssertEqual(Set(cachedProjects.map(\.id)), Set([original.id, added.id]))
    }

    func testComposerProjectRefreshFailureKeepsSavedCatalog() async throws {
        let container = try makeContainer()
        let activeAccount = account(id: "account")
        let original = TimenProject(id: "original", name: "Original", clientName: "Client")
        let gateway = AccountLifecycleGateway(
            account: activeAccount,
            projects: [original],
            tags: [],
            entries: []
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        await model.signIn()
        await gateway.setProjectsUnavailable(true)

        model.presentNewTimer()
        await waitForComposerProjectRefresh(model)

        XCTAssertEqual(model.projects, [original])
        XCTAssertEqual(try OfflineStore(container: container).projects(), [original])
        XCTAssertEqual(model.composerProjectRefreshMessage, "Couldn’t refresh projects. Showing saved projects.")
    }

    func testDismissingComposerClearsItsPresentationAndMutationContext() async throws {
        let container = try makeContainer()
        let activeAccount = account(id: "account")
        let gateway = AccountLifecycleGateway(
            account: activeAccount,
            projects: [],
            tags: [],
            entries: []
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        await model.signIn()
        model.presentNewTimer()
        XCTAssertNotNil(model.composerMode)

        model.dismissComposer()

        XCTAssertNil(model.composerMode)
        XCTAssertFalse(model.isRefreshingComposerProjects)
        XCTAssertNil(model.composerProjectRefreshMessage)

        await model.startTimer(.empty, source: "timer-composer")
        let startCalls = await gateway.startTimerCallCount()
        XCTAssertEqual(startCalls, 0)
        XCTAssertEqual(model.errorMessage, "That timer form belongs to a previous Timen account.")
    }

    func testOpeningAnotherFormKeepsTheExistingDraftAndRequestsItsWindow() async throws {
        let container = try makeContainer()
        let activeAccount = account(id: "account")
        let project = TimenProject(id: "project", name: "Project", clientName: "Client")
        let existingEntry = entry(id: "entry", project: project, note: "Existing")
        let gateway = AccountLifecycleGateway(
            account: activeAccount,
            projects: [project],
            tags: [],
            entries: [existingEntry]
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        await model.signIn()
        model.presentNewTimer()
        let firstRequest = try XCTUnwrap(model.composerPresentationRequestID)

        model.presentEdit(existingEntry)

        guard case .new? = model.composerMode else {
            return XCTFail("Opening another form should preserve the existing draft")
        }
        XCTAssertNotEqual(model.composerPresentationRequestID, firstRequest)
    }

    func testStoppingTimerOutsideTheFormDismissesRunningComposer() async throws {
        let container = try makeContainer()
        let activeAccount = account(id: "account")
        let gateway = AccountLifecycleGateway(
            account: activeAccount,
            projects: [],
            tags: [],
            entries: []
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        await model.signIn()
        model.presentNewTimer()
        await model.startTimer(.empty)
        model.presentRunningTimer()
        guard case .running? = model.composerMode else {
            return XCTFail("Expected the running timer form")
        }

        await model.stopTimer(source: "status-bar")

        XCTAssertNil(model.runningTimer)
        XCTAssertNil(model.composerMode)
    }

    func testManualTimeUsesCompletedLogMutationAndRejectsFutureEnd() async throws {
        let container = try makeContainer()
        let activeAccount = account(id: "account")
        let project = TimenProject(id: "project", name: "Project", clientName: "Client")
        let gateway = AccountLifecycleGateway(
            account: activeAccount,
            projects: [project],
            tags: [],
            entries: []
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        await model.signIn()
        model.presentNewTimer()
        let end = Date.now.addingTimeInterval(-60)
        let start = end.addingTimeInterval(-3_600)
        let draft = TimerDraft(projectID: project.id, tagIDs: [], note: "Yesterday", billable: false)

        await model.logTime(start: start, end: end, draft: draft, source: "timer-composer")

        let lastLogTimeCall = await gateway.lastLogTimeCall()
        let logged = try XCTUnwrap(lastLogTimeCall)
        XCTAssertEqual(logged.start, start)
        XCTAssertEqual(logged.end, end)
        XCTAssertEqual(logged.draft, draft.enforcingBillable)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.duration, 3_600)
        XCTAssertNil(model.composerMode)

        model.presentNewTimer()
        let futureEnd = Date.now.addingTimeInterval(3_600)
        await model.logTime(
            start: futureEnd.addingTimeInterval(-600),
            end: futureEnd,
            draft: draft,
            source: "timer-composer"
        )

        let logTimeCallCount = await gateway.logTimeCallCount()
        XCTAssertEqual(logTimeCallCount, 1)
        XCTAssertNotNil(model.composerMode)
        XCTAssertEqual(model.errorMessage, "Time entries cannot end in the future.")

        let savedEntry = try XCTUnwrap(model.entries.first)
        model.presentEdit(savedEntry)
        await model.updateEntry(
            savedEntry,
            draft: draft,
            start: Date.now,
            end: Date.now.addingTimeInterval(3_600)
        )
        XCTAssertNotNil(model.composerMode)
        XCTAssertEqual(model.errorMessage, "Time entries cannot end in the future.")
    }

    func testContinuedEntryKeepsItsBaseDurationOutsideTheVisibleWeek() async throws {
        let container = try makeContainer()
        let activeAccount = account(id: "account")
        let project = TimenProject(id: "project", name: "Project", clientName: "Client")
        let originalStart = Date.now.addingTimeInterval(-7_200)
        let original = TimeEntry(
            id: "entry", remoteID: "entry", start: originalStart,
            end: originalStart.addingTimeInterval(3_600),
            projectID: project.id, projectName: project.name, clientName: project.clientName,
            note: "Continued work", tags: [], billable: true, syncState: .synced
        )
        let gateway = AccountLifecycleGateway(
            account: activeAccount,
            projects: [project],
            tags: [],
            entries: [original]
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        await model.signIn()
        await model.restartEntry(original)
        let continuationStart = try XCTUnwrap(model.runningTimer?.startedAt)
        let continuationEnd = continuationStart.addingTimeInterval(600)

        // Navigating to another week replaces the visible entries array. The
        // persisted focused-entry snapshot must still supply the continuation base.
        model.entries = []
        model.now = continuationEnd
        XCTAssertEqual(model.runningDisplayDuration, 4_200, accuracy: 0.01)

        await model.stopTimer(at: continuationEnd)

        let recordedDuration = await gateway.lastDurationUpdate()
        let requestedDuration = try XCTUnwrap(recordedDuration)
        XCTAssertEqual(requestedDuration, 4_200, accuracy: 0.01)
        XCTAssertNil(model.runningTimer)
        XCTAssertFalse(model.isContinuingEntry)
        let savedEntry = try XCTUnwrap(model.entries.first)
        XCTAssertEqual(savedEntry.duration, 4_200, accuracy: 0.01)
    }

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
        XCTAssertNil(try store.cachedAccount())
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

    func testRetrySignInCancelsThePendingAttemptAndKeepsTheReplacementState() async throws {
        let container = try makeContainer()
        let activeAccount = account(id: "account")
        let gateway = AccountLifecycleGateway(
            account: activeAccount,
            projects: [],
            tags: [],
            entries: [],
            firstAuthenticationWaitsForCancellation: true
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        let originalAttempt = Task { await model.signIn() }
        await waitForAuthenticationRequests(1, gateway: gateway)
        XCTAssertEqual(model.authenticationState, .signingIn)

        let replacementAttempt = Task { await model.retrySignIn() }
        await waitForAuthenticationRequests(2, gateway: gateway)
        await waitForAuthenticationState(.signedIn, model: model)
        await replacementAttempt.value
        await originalAttempt.value

        let authenticationRequests = await gateway.authenticationRequestCount()
        let maximumConcurrentAuthenticationRequests = await gateway.maximumConcurrentAuthenticationRequestCount()
        XCTAssertEqual(authenticationRequests, 2)
        XCTAssertEqual(maximumConcurrentAuthenticationRequests, 1)
        XCTAssertEqual(model.authenticationState, .signedIn)
        XCTAssertEqual(model.account, activeAccount)
        XCTAssertNil(model.errorMessage)
    }

    func testCancelSignInReturnsToSignedOutWithoutShowingAnError() async throws {
        let container = try makeContainer()
        let gateway = AccountLifecycleGateway(
            account: account(id: "account"),
            projects: [],
            tags: [],
            entries: [],
            firstAuthenticationWaitsForCancellation: true
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        let attempt = Task { await model.signIn() }
        await waitForAuthenticationRequests(1, gateway: gateway)
        await model.cancelSignIn()
        await attempt.value

        XCTAssertEqual(model.authenticationState, .signedOut)
        XCTAssertNil(model.errorMessage)
        let authenticationRequests = await gateway.authenticationRequestCount()
        XCTAssertEqual(authenticationRequests, 1)
    }

    func testCancelAfterAuthenticationRemovesCredentialsCreatedByThatAttempt() async throws {
        let container = try makeContainer()
        let gateway = AccountLifecycleGateway(
            account: account(id: "account"),
            projects: [],
            tags: [],
            entries: [],
            accountRequestWaitsForCancellation: true
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        let attempt = Task { await model.signIn() }
        await waitForAccountRequests(1, gateway: gateway)
        let credentialsBeforeCancellation = await gateway.hasStoredCredentials()
        XCTAssertTrue(credentialsBeforeCancellation)

        await model.cancelSignIn()
        await attempt.value

        let hasStoredCredentials = await gateway.hasStoredCredentials()
        let signOutRequests = await gateway.signOutRequestCount()
        XCTAssertFalse(hasStoredCredentials)
        XCTAssertEqual(signOutRequests, 1)
        XCTAssertEqual(model.authenticationState, .signedOut)
        XCTAssertNil(model.errorMessage)
    }

    func testFailedRetryDoesNotLeaveCredentialsFromEitherAttempt() async throws {
        let container = try makeContainer()
        let gateway = AccountLifecycleGateway(
            account: account(id: "account"),
            projects: [],
            tags: [],
            entries: [],
            failProjects: true,
            accountRequestWaitsForCancellation: true
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        let originalAttempt = Task { await model.signIn() }
        await waitForAccountRequests(1, gateway: gateway)
        let replacementAttempt = Task { await model.retrySignIn() }
        await replacementAttempt.value
        await originalAttempt.value

        let hasStoredCredentials = await gateway.hasStoredCredentials()
        let signOutRequests = await gateway.signOutRequestCount()
        let authenticationEvents = await gateway.authenticationEventsSnapshot()
        XCTAssertFalse(hasStoredCredentials)
        XCTAssertEqual(signOutRequests, 2)
        XCTAssertEqual(authenticationEvents, ["authenticate-1", "signOut", "authenticate-2", "signOut"])
        XCTAssertEqual(model.authenticationState, .signedOut)
        XCTAssertEqual(model.errorMessage, AccountLifecycleGatewayError.projectsUnavailable.localizedDescription)
    }

    func testSignOutWaitsForPendingAuthenticationToFinish() async throws {
        let container = try makeContainer()
        let gateway = AccountLifecycleGateway(
            account: account(id: "account"),
            projects: [],
            tags: [],
            entries: [],
            firstAuthenticationWaitsForCancellation: true
        )
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = makeModel(container: container, gateway: gateway, defaults: defaults)

        let attempt = Task { await model.signIn() }
        await waitForAuthenticationRequests(1, gateway: gateway)
        await model.signOut()
        await attempt.value

        let signOutOverlappedAuthentication = await gateway.didSignOutWhileAuthenticating()
        XCTAssertFalse(signOutOverlappedAuthentication)
        XCTAssertEqual(model.authenticationState, .signedOut)
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

    private func waitForComposerProjectRefresh(_ model: AppModel) async {
        for _ in 0 ..< 1_000 {
            if !model.isRefreshingComposerProjects { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the composer project refresh")
    }

    private func waitForAuthenticationRequests(
        _ expectedCount: Int,
        gateway: AccountLifecycleGateway
    ) async {
        for _ in 0 ..< 1_000 {
            if await gateway.authenticationRequestCount() >= expectedCount { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for authentication attempt \(expectedCount)")
    }

    private func waitForAuthenticationState(
        _ expectedState: AuthenticationState,
        model: AppModel
    ) async {
        for _ in 0 ..< 1_000 {
            if model.authenticationState == expectedState { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for authentication state \(expectedState)")
    }

    private func waitForAccountRequests(
        _ expectedCount: Int,
        gateway: AccountLifecycleGateway
    ) async {
        for _ in 0 ..< 1_000 {
            if await gateway.accountRequestCount() >= expectedCount { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for account request \(expectedCount)")
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

private struct LogTimeCall: Sendable {
    var start: Date
    var end: Date
    var draft: TimerDraft
}

private actor AccountLifecycleGateway: TimenGateway {
    private let currentAccount: TimenAccount
    private var projectValues: [TimenProject]
    private let tagValues: [TimenTag]
    private let entryValues: [TimeEntry]
    private var failProjects: Bool
    private var projectRequests = 0
    private var startCalls = 0
    private var logTimeCalls: [LogTimeCall] = []
    private var durationUpdates: [TimeInterval] = []
    private let firstAuthenticationWaitsForCancellation: Bool
    private var authenticationRequests = 0
    private var activeAuthenticationRequests = 0
    private var maximumConcurrentAuthenticationRequests = 0
    private var signOutOverlappedAuthentication = false
    private let accountRequestWaitsForCancellation: Bool
    private var accountRequests = 0
    private var signOutRequests = 0
    private var credentialsStored = false
    private var authenticationEvents: [String] = []

    init(
        account: TimenAccount,
        projects: [TimenProject],
        tags: [TimenTag],
        entries: [TimeEntry],
        failProjects: Bool = false,
        firstAuthenticationWaitsForCancellation: Bool = false,
        accountRequestWaitsForCancellation: Bool = false
    ) {
        currentAccount = account
        projectValues = projects
        tagValues = tags
        entryValues = entries
        self.failProjects = failProjects
        self.firstAuthenticationWaitsForCancellation = firstAuthenticationWaitsForCancellation
        self.accountRequestWaitsForCancellation = accountRequestWaitsForCancellation
    }

    func startTimerCallCount() -> Int { startCalls }
    func logTimeCallCount() -> Int { logTimeCalls.count }
    func lastLogTimeCall() -> LogTimeCall? { logTimeCalls.last }
    func lastDurationUpdate() -> TimeInterval? { durationUpdates.last }
    func projectRequestCount() -> Int { projectRequests }
    func authenticationRequestCount() -> Int { authenticationRequests }
    func maximumConcurrentAuthenticationRequestCount() -> Int { maximumConcurrentAuthenticationRequests }
    func didSignOutWhileAuthenticating() -> Bool { signOutOverlappedAuthentication }
    func accountRequestCount() -> Int { accountRequests }
    func signOutRequestCount() -> Int { signOutRequests }
    func hasStoredCredentials() -> Bool { credentialsStored }
    func authenticationEventsSnapshot() -> [String] { authenticationEvents }
    func setProjects(_ projects: [TimenProject]) { projectValues = projects }
    func setProjectsUnavailable(_ unavailable: Bool) { failProjects = unavailable }
    func isAuthenticated() async -> Bool { true }
    func authenticate() async throws {
        authenticationRequests += 1
        authenticationEvents.append("authenticate-\(authenticationRequests)")
        activeAuthenticationRequests += 1
        maximumConcurrentAuthenticationRequests = max(
            maximumConcurrentAuthenticationRequests,
            activeAuthenticationRequests
        )
        defer { activeAuthenticationRequests -= 1 }
        if firstAuthenticationWaitsForCancellation, authenticationRequests == 1 {
            try await Task.sleep(for: .seconds(60))
        }
        credentialsStored = true
    }
    func signOut() async throws {
        signOutRequests += 1
        authenticationEvents.append("signOut")
        signOutOverlappedAuthentication = activeAuthenticationRequests > 0
        credentialsStored = false
    }
    func validateCapabilities() async throws {}
    func account() async throws -> TimenAccount {
        accountRequests += 1
        if accountRequestWaitsForCancellation, accountRequests == 1 {
            try await Task.sleep(for: .seconds(60))
        }
        return currentAccount
    }
    func runningTimer() async throws -> RunningTimer? { nil }
    func projects() async throws -> [TimenProject] {
        projectRequests += 1
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
    func stopTimer() async throws -> TimeEntry {
        let end = Date.now
        return TimeEntry(
            id: "stopped-entry",
            remoteID: "stopped-entry",
            start: end.addingTimeInterval(-60),
            end: end,
            projectID: nil,
            projectName: nil,
            clientName: nil,
            note: "",
            tags: [],
            billable: true,
            syncState: .synced
        )
    }
    func logTime(start: Date, end: Date, draft: TimerDraft) async throws -> TimeEntry {
        logTimeCalls.append(LogTimeCall(start: start, end: end, draft: draft))
        let project = projectValues.first { $0.id == draft.projectID }
        return TimeEntry(
            id: "logged-\(logTimeCalls.count)",
            remoteID: "logged-\(logTimeCalls.count)",
            start: start,
            end: end,
            projectID: project?.id,
            projectName: project?.name,
            clientName: project?.clientName,
            note: draft.note,
            tags: tagValues.filter { draft.tagIDs.contains($0.id) },
            billable: draft.billable,
            syncState: .synced
        )
    }
    func updateEntry(
        id _: String,
        draft _: TimerDraft,
        start _: Date?,
        end _: Date?
    ) async throws -> TimeEntry {
        throw AccountLifecycleGatewayError.unsupportedMutation
    }
    func updateEntryDuration(id: String, draft: TimerDraft, duration: TimeInterval) async throws -> TimeEntry {
        guard var entry = entryValues.first(where: { $0.remoteID == id }) else {
            throw AccountLifecycleGatewayError.unsupportedMutation
        }
        durationUpdates.append(duration)
        let project = projectValues.first { $0.id == draft.projectID }
        entry.end = entry.start.addingTimeInterval(duration)
        entry.projectID = project?.id
        entry.projectName = project?.name
        entry.clientName = project?.clientName
        entry.note = draft.note
        entry.tags = tagValues.filter { draft.tagIDs.contains($0.id) }
        entry.billable = draft.billable
        return entry
    }
    func deleteEntry(id _: String) async throws { throw AccountLifecycleGatewayError.unsupportedMutation }
}
