import SwiftData
import XCTest
@testable import TimenBar

@MainActor
final class OfflineStoreTests: XCTestCase {
    private func makeContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Schema(PersistenceSchema.models), configurations: [configuration])
    }

    func testReadCacheRoundTrip() throws {
        let store = OfflineStore(container: try makeContainer())
        try store.prepareForAccount(account(id: "account-a"))
        let projects = [TimenProject(id: "p", name: "Build", clientName: "Acme")]
        let tags = [TimenTag(id: "t", name: "Code")]
        let start = Date(timeIntervalSince1970: 1_000)
        let entry = TimeEntry(
            id: "remote:1", remoteID: "1", start: start, end: start.addingTimeInterval(900),
            projectID: "p", projectName: "Build", clientName: "Acme", note: "Cached",
            tags: tags, billable: true, syncState: .synced
        )

        try store.replaceProjects(projects)
        try store.replaceTags(tags)
        try store.upsertEntries([entry])

        XCTAssertEqual(try store.projects(), projects)
        XCTAssertEqual(try store.tags(), tags)
        XCTAssertEqual(
            try store.entries(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(1_000)),
            [entry]
        )
    }

    func testReplacingWeekCacheLeavesOtherWeeksAlone() throws {
        let store = OfflineStore(container: try makeContainer())
        try store.prepareForAccount(account(id: "account-a"))
        let firstStart = Date(timeIntervalSince1970: 1_000)
        let laterStart = Date(timeIntervalSince1970: 20_000)
        let stale = entry(id: "1", start: firstStart, note: "Stale")
        let outsideWindow = entry(id: "2", start: laterStart, note: "Other week")
        let refreshed = entry(id: "1", start: firstStart, note: "Refreshed")
        try store.upsertEntries([stale, outsideWindow])

        try store.replaceEntries(
            [refreshed],
            from: firstStart.addingTimeInterval(-10),
            to: firstStart.addingTimeInterval(10)
        )

        XCTAssertEqual(
            try store.entries(from: firstStart.addingTimeInterval(-10), to: firstStart.addingTimeInterval(10)),
            [refreshed]
        )
        XCTAssertEqual(
            try store.entries(from: laterStart.addingTimeInterval(-10), to: laterStart.addingTimeInterval(10)),
            [outsideWindow]
        )
    }

    func testLegacyCleanupPreservesFavoritesAndRemoteActiveSegment() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let favorite = Favorite(
            id: UUID(), name: "Build", projectID: "p", tagIDs: [], note: "", billable: true, sortOrder: 0
        )
        let remoteSegment = ActiveTimerSegment(
            id: UUID(), startedAt: .now, endedAt: nil, draft: .empty, remoteTimerID: "42"
        )
        let localSegment = ActiveTimerSegment(
            id: UUID(), startedAt: .now, endedAt: nil, draft: .empty, remoteTimerID: nil
        )
        let pendingEntry = entry(id: "local:1", start: .now, note: "Legacy")
        let pendingRecord = CachedEntry(entry: pendingEntry)
        pendingRecord.remoteID = nil
        pendingRecord.syncStateRaw = "pending"
        let mutationID = UUID()

        context.insert(CachedAccountRecord(account: account(id: "account-a")))
        context.insert(FavoriteRecord(favorite: favorite))
        context.insert(PendingSegmentRecord(segment: remoteSegment))
        context.insert(PendingSegmentRecord(segment: localSegment))
        context.insert(pendingRecord)
        context.insert(OutboxRecord(
            id: mutationID,
            sequence: 1,
            kindRaw: "startTimer",
            entryID: pendingEntry.id,
            payload: Data(),
            stateRaw: "pending",
            attempts: 0,
            createdAt: .now,
            lastError: nil
        ))
        context.insert(ConflictRecord(
            id: UUID(),
            mutationID: mutationID,
            title: "Legacy",
            explanation: "Legacy",
            localSummary: "Local",
            remoteSummary: "Remote",
            createdAt: .now
        ))
        try context.save()

        let store = OfflineStore(container: container)
        try store.discardLegacyOfflineMutationState()

        XCTAssertEqual(try store.favorites(), [favorite])
        XCTAssertEqual(try store.activeSegment(), remoteSegment)
        XCTAssertTrue(try store.entries(from: .distantPast, to: .distantFuture).isEmpty)

        let verificationContext = ModelContext(container)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<OutboxRecord>()).isEmpty)
        XCTAssertTrue(try verificationContext.fetch(FetchDescriptor<ConflictRecord>()).isEmpty)
    }

    func testChangingAccountClearsEveryAccountOwnedRecord() throws {
        let store = OfflineStore(container: try makeContainer())
        let accountA = account(id: "account-a")
        let accountB = account(id: "account-b")
        let project = TimenProject(id: "shared-id", name: "Account A", clientName: "A")
        let tag = TimenTag(id: "shared-id", name: "Account A Tag")
        let cachedEntry = entry(id: "shared-id", start: .now, note: "Account A entry")
        let favorite = Favorite(
            id: UUID(), name: project.name, projectID: project.id,
            tagIDs: [tag.id], note: "Account A note", billable: false, sortOrder: 0
        )
        let segment = ActiveTimerSegment(
            id: UUID(), startedAt: .now, endedAt: nil,
            draft: TimerDraft(projectID: project.id, tagIDs: [tag.id], note: "Account A", billable: true),
            remoteTimerID: "shared-id"
        )

        XCTAssertEqual(try store.prepareForAccount(accountA), .initialized)
        try store.replaceProjects([project])
        try store.replaceTags([tag])
        try store.upsertEntries([cachedEntry])
        try store.saveFavorite(favorite)
        try store.saveSegment(segment)

        XCTAssertEqual(try store.prepareForAccount(accountB), .changed)
        XCTAssertEqual(try store.cachedAccount(), accountB)
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(try store.tags().isEmpty)
        XCTAssertTrue(try store.entries(from: .distantPast, to: .distantFuture).isEmpty)
        XCTAssertTrue(try store.favorites().isEmpty)
        XCTAssertNil(try store.activeSegment())
    }

    func testUnownedLegacyCacheIsNeverAdopted() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.insert(CachedProject(id: "legacy", name: "Other account", clientName: nil, isActive: true))
        context.insert(FavoriteRecord(favorite: Favorite(
            id: UUID(), name: "Other account", projectID: "legacy",
            tagIDs: [], note: "", billable: true, sortOrder: 0
        )))
        try context.save()

        let store = OfflineStore(container: container)
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(try store.favorites().isEmpty)
        XCTAssertEqual(try store.prepareForAccount(account(id: "account-b")), .initialized)
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(try store.favorites().isEmpty)
    }

    func testFavoriteMigrationKeepsOnlyProjectSemantics() throws {
        let container = try makeContainer()
        let store = OfflineStore(container: container)
        try store.prepareForAccount(account(id: "account-a"))
        let project = TimenProject(id: "p", name: "Current Project Name", clientName: "Acme")
        try store.replaceProjects([project])

        let context = ModelContext(container)
        let record = FavoriteRecord(favorite: Favorite(
            id: UUID(), name: "Old Name", projectID: project.id,
            tagIDs: [], note: "", billable: true, sortOrder: 7
        ))
        record.tagIDsData = try JSONEncoder().encode(["legacy-tag"])
        record.note = "legacy note"
        record.billable = false
        context.insert(record)
        context.insert(FavoriteRecord(favorite: Favorite(
            id: UUID(), name: "Duplicate", projectID: project.id,
            tagIDs: [], note: "", billable: true, sortOrder: 8
        )))
        context.insert(FavoriteRecord(favorite: Favorite(
            id: UUID(), name: "Missing", projectID: "missing",
            tagIDs: [], note: "", billable: true, sortOrder: 9
        )))
        try context.save()

        let favorites = try store.reconcileFavorites(with: [project])

        XCTAssertEqual(favorites.count, 1)
        XCTAssertEqual(favorites[0].name, project.name)
        XCTAssertEqual(favorites[0].projectID, project.id)
        XCTAssertEqual(favorites[0].tagIDs, [])
        XCTAssertEqual(favorites[0].note, "")
        XCTAssertTrue(favorites[0].billable)
        XCTAssertEqual(favorites[0].sortOrder, 0)

        let verificationContext = ModelContext(container)
        let persisted = try verificationContext.fetch(FetchDescriptor<FavoriteRecord>())
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: persisted[0].tagIDsData), [])
        XCTAssertEqual(persisted[0].note, "")
        XCTAssertTrue(persisted[0].billable)
    }

    func testClearingAccountDataAlsoRemovesCacheIdentity() throws {
        let store = OfflineStore(container: try makeContainer())
        try store.prepareForAccount(account(id: "account-a"))
        try store.replaceProjects([TimenProject(id: "p", name: "Build", clientName: nil)])

        try store.clearAccountData()

        XCTAssertNil(try store.cachedAccount())
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertThrowsError(try store.replaceProjects([])) { error in
            XCTAssertEqual(error as? OfflineStoreError, .accountNotBound)
        }
    }

    private func entry(id: String, start: Date, note: String) -> TimeEntry {
        TimeEntry(
            id: id,
            remoteID: id,
            start: start,
            end: start.addingTimeInterval(600),
            projectID: "p",
            projectName: "Build",
            clientName: "Acme",
            note: note,
            tags: [],
            billable: true,
            syncState: .synced
        )
    }

    private func account(id: String) -> TimenAccount {
        TimenAccount(
            id: id,
            name: id,
            email: "\(id)@example.com",
            teamName: "Team \(id)",
            role: "member",
            timeZoneIdentifier: "UTC"
        )
    }
}
