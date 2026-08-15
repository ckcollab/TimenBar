import Foundation
import SwiftData

@MainActor
final class OfflineStore {
    private let context: ModelContext
    private let encoder = JSONEncoder()

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func projects() throws -> [TimenProject] {
        let values = try context.fetch(FetchDescriptor<CachedProject>(sortBy: [SortDescriptor(\.name)]))
        return values.map { TimenProject(id: $0.id, name: $0.name, clientName: $0.clientName, isActive: $0.isActive) }
    }

    func replaceProjects(_ projects: [TimenProject]) throws {
        let existing = try context.fetch(FetchDescriptor<CachedProject>())
        existing.forEach(context.delete)
        projects.forEach { context.insert(CachedProject(id: $0.id, name: $0.name, clientName: $0.clientName, isActive: $0.isActive)) }
        try context.save()
    }

    func tags() throws -> [TimenTag] {
        try context.fetch(FetchDescriptor<CachedTag>(sortBy: [SortDescriptor(\.name)]))
            .map { TimenTag(id: $0.id, name: $0.name) }
    }

    func replaceTags(_ tags: [TimenTag]) throws {
        let existing = try context.fetch(FetchDescriptor<CachedTag>())
        existing.forEach(context.delete)
        tags.forEach { context.insert(CachedTag(id: $0.id, name: $0.name)) }
        try context.save()
    }

    func entries(from start: Date, to end: Date) throws -> [TimeEntry] {
        let descriptor = FetchDescriptor<CachedEntry>(
            predicate: #Predicate { $0.start >= start && $0.start < end },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        return try context.fetch(descriptor).map(\.domain)
    }

    func upsertEntries(_ entries: [TimeEntry]) throws {
        for entry in entries {
            let id = entry.id
            var descriptor = FetchDescriptor<CachedEntry>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let current = try context.fetch(descriptor).first {
                current.remoteID = entry.remoteID
                current.start = entry.start
                current.end = entry.end
                current.projectID = entry.projectID
                current.projectName = entry.projectName
                current.clientName = entry.clientName
                current.note = entry.note
                current.tagData = (try? encoder.encode(entry.tags)) ?? Data()
                current.billable = entry.billable
                current.syncStateRaw = entry.syncState.rawValue
                current.updatedAt = .now
            } else {
                context.insert(CachedEntry(entry: entry))
            }
        }
        try context.save()
    }

    func replaceSyncedEntries(_ entries: [TimeEntry], from start: Date, to end: Date) throws {
        let descriptor = FetchDescriptor<CachedEntry>(predicate: #Predicate {
            $0.start >= start && $0.start < end
        })
        let oldSyncedEntries = try context.fetch(descriptor).filter { $0.syncStateRaw == SyncState.synced.rawValue }
        oldSyncedEntries.forEach(context.delete)
        try context.save()
        try upsertEntries(entries)
    }

    func deleteEntry(id: String) throws {
        let entryID = id
        let descriptor = FetchDescriptor<CachedEntry>(predicate: #Predicate { $0.id == entryID })
        try context.fetch(descriptor).forEach(context.delete)
        try context.save()
    }

    func favorites() throws -> [Favorite] {
        try context.fetch(FetchDescriptor<FavoriteRecord>(sortBy: [SortDescriptor(\.sortOrder)]))
            .map(\.domain)
    }

    func saveFavorite(_ favorite: Favorite) throws {
        let favoriteID = favorite.id
        var descriptor = FetchDescriptor<FavoriteRecord>(predicate: #Predicate { $0.id == favoriteID })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.name = favorite.name
            record.projectID = favorite.projectID
            record.tagIDsData = (try? encoder.encode(favorite.tagIDs)) ?? Data()
            record.note = favorite.note
            record.billable = favorite.billable
            record.sortOrder = favorite.sortOrder
        } else {
            context.insert(FavoriteRecord(favorite: favorite))
        }
        try context.save()
    }

    func deleteFavorite(id: UUID) throws {
        let favoriteID = id
        let descriptor = FetchDescriptor<FavoriteRecord>(predicate: #Predicate { $0.id == favoriteID })
        try context.fetch(descriptor).forEach(context.delete)
        try context.save()
    }

    func enqueue(kind: OutboxMutationKind, entryID: String?, payload: some Encodable) throws -> QueuedMutation {
        let descriptor = FetchDescriptor<OutboxRecord>(sortBy: [SortDescriptor(\.sequence, order: .reverse)])
        let nextSequence = (try context.fetch(descriptor).first?.sequence ?? 0) + 1
        let mutation = QueuedMutation(
            id: UUID(),
            sequence: nextSequence,
            kind: kind,
            entryID: entryID,
            payload: try encoder.encode(payload),
            state: .pending,
            attempts: 0,
            createdAt: .now,
            lastError: nil
        )
        context.insert(OutboxRecord(mutation: mutation))
        try context.save()
        return mutation
    }

    func pendingMutations() throws -> [QueuedMutation] {
        let descriptor = FetchDescriptor<OutboxRecord>(
            predicate: #Predicate { $0.stateRaw == "pending" || $0.stateRaw == "failed" },
            sortBy: [SortDescriptor(\.sequence)]
        )
        return try context.fetch(descriptor).compactMap(\.domain)
    }

    func mutation(id: UUID) throws -> QueuedMutation? {
        let mutationID = id
        var descriptor = FetchDescriptor<OutboxRecord>(predicate: #Predicate { $0.id == mutationID })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.domain
    }

    func cancelPendingStart(entryID: String) throws {
        let localEntryID = entryID
        let descriptor = FetchDescriptor<OutboxRecord>(predicate: #Predicate {
            $0.entryID == localEntryID && $0.kindRaw == "startTimer"
        })
        let cancellable = try context.fetch(descriptor).filter {
            $0.stateRaw == OutboxMutationState.pending.rawValue || $0.stateRaw == OutboxMutationState.failed.rawValue
        }
        cancellable.forEach(context.delete)
        try context.save()
    }

    func setMutation(_ id: UUID, state: OutboxMutationState, error: String? = nil) throws {
        let mutationID = id
        var descriptor = FetchDescriptor<OutboxRecord>(predicate: #Predicate { $0.id == mutationID })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return }
        record.stateRaw = state.rawValue
        record.lastError = error
        if state == .sending { record.attempts += 1 }
        try context.save()
    }

    func removeAppliedMutations() throws {
        let descriptor = FetchDescriptor<OutboxRecord>(predicate: #Predicate { $0.stateRaw == "applied" })
        try context.fetch(descriptor).forEach(context.delete)
        try context.save()
    }

    func conflicts() throws -> [SyncConflict] {
        try context.fetch(FetchDescriptor<ConflictRecord>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))
            .map(\.domain)
    }

    func addConflict(_ conflict: SyncConflict) throws {
        context.insert(ConflictRecord(conflict: conflict))
        try setMutation(conflict.mutationID, state: .needsReview, error: conflict.explanation)
        try context.save()
    }

    func resolveConflict(id: UUID) throws {
        let conflictID = id
        let descriptor = FetchDescriptor<ConflictRecord>(predicate: #Predicate { $0.id == conflictID })
        try context.fetch(descriptor).forEach(context.delete)
        try context.save()
    }

    func saveSegment(_ segment: PendingTimerSegment) throws {
        context.insert(PendingSegmentRecord(segment: segment))
        try context.save()
    }

    func activeSegment() throws -> PendingTimerSegment? {
        let descriptor = FetchDescriptor<PendingSegmentRecord>(predicate: #Predicate { $0.endedAt == nil })
        return try context.fetch(descriptor).first?.domain
    }

    func updateActiveSegment(draft: TimerDraft? = nil, remoteTimerID: String? = nil) throws {
        var descriptor = FetchDescriptor<PendingSegmentRecord>(predicate: #Predicate { $0.endedAt == nil })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return }
        if let draft { record.draftData = (try? encoder.encode(draft)) ?? record.draftData }
        if let remoteTimerID { record.remoteTimerID = remoteTimerID }
        try context.save()
    }

    func closeActiveSegment(at date: Date) throws -> PendingTimerSegment? {
        var descriptor = FetchDescriptor<PendingSegmentRecord>(predicate: #Predicate { $0.endedAt == nil })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return nil }
        record.endedAt = date
        try context.save()
        return record.domain
    }
}
