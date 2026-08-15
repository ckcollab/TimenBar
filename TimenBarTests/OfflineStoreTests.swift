import SwiftData
import XCTest
@testable import TimenBar

@MainActor
final class OfflineStoreTests: XCTestCase {
    private func makeStore() throws -> OfflineStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Schema(PersistenceSchema.models), configurations: [configuration])
        return OfflineStore(container: container)
    }

    func testOutboxPreservesInsertionOrder() throws {
        let store = try makeStore()
        let draft = TimerDraft(projectID: "p", tagIDs: [], note: "one", billable: false)
        let first = try store.enqueue(kind: .startTimer, entryID: "local:1", payload: StartTimerPayload(draft: draft, requestedAt: .now))
        let second = try store.enqueue(kind: .deleteEntry, entryID: "remote:2", payload: DeleteEntryPayload(entryID: "2", baseSummary: "two"))

        let pending = try store.pendingMutations()
        XCTAssertEqual(pending.map(\.id), [first.id, second.id])
        XCTAssertLessThan(first.sequence, second.sequence)
    }

    func testOfflineStopCancelsDependentStart() throws {
        let store = try makeStore()
        let draft = TimerDraft.empty
        _ = try store.enqueue(kind: .startTimer, entryID: "local:timer", payload: StartTimerPayload(draft: draft, requestedAt: .now))
        try store.cancelPendingStart(entryID: "local:timer")
        XCTAssertTrue(try store.pendingMutations().isEmpty)
    }

    func testConflictRetainsMutationForResolution() throws {
        let store = try makeStore()
        let mutation = try store.enqueue(
            kind: .updateEntry,
            entryID: "entry",
            payload: UpdateEntryPayload(entryID: "remote", draft: .empty, start: nil, end: nil, baseSummary: "base")
        )
        let conflict = SyncConflict(
            id: UUID(), mutationID: mutation.id, title: "Changed elsewhere", explanation: "Review",
            localSummary: "local", remoteSummary: "remote", createdAt: .now
        )
        try store.addConflict(conflict)

        XCTAssertEqual(try store.mutation(id: mutation.id)?.state, .needsReview)
        XCTAssertEqual(try store.conflicts(), [conflict])
    }

    func testCacheRoundTripKeepsSyncState() throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 1_000)
        let entry = TimeEntry(
            id: "local:1", remoteID: nil, start: start, end: start.addingTimeInterval(900),
            projectID: "p", projectName: "Build", clientName: "Acme", note: "Offline",
            tags: [TimenTag(id: "t", name: "Code")], billable: true, syncState: .pending
        )
        try store.upsertEntries([entry])
        let loaded = try store.entries(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(1_000))
        XCTAssertEqual(loaded, [entry])
    }
}
