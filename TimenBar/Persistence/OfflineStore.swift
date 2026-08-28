import Foundation
import SwiftData

enum CacheAccountTransition: Equatable {
    case initialized
    case unchanged
    case changed
}

enum OfflineStoreError: LocalizedError, Equatable {
    case accountNotBound
    case favoriteRequiresProject

    var errorDescription: String? {
        switch self {
        case .accountNotBound:
            "The local cache is not bound to a Timen account."
        case .favoriteRequiresProject:
            "Favorites must reference a project."
        }
    }
}

@MainActor
final class OfflineStore {
    private let context: ModelContext
    private let encoder = JSONEncoder()

    init(container: ModelContainer) {
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func cachedAccount() throws -> TimenAccount? {
        try accountRecord()?.domain
    }

    /// Binds the single-account cache to `account`. Any unowned legacy data or
    /// data belonging to another account is removed before the new identity is
    /// persisted, so remote identifiers can never collide across accounts.
    @discardableResult
    func prepareForAccount(_ account: TimenAccount) throws -> CacheAccountTransition {
        let existing = try accountRecord()
        let transition: CacheAccountTransition
        if let existing {
            if existing.accountID == account.id {
                transition = .unchanged
            } else {
                try clearCachedContent()
                transition = .changed
            }
            existing.accountID = account.id
            existing.accountData = try encoder.encode(account)
            existing.updatedAt = .now
        } else {
            // Data written before account binding was introduced has no
            // trustworthy owner and must not be adopted by the current login.
            try clearCachedContent()
            context.insert(CachedAccountRecord(account: account))
            transition = .initialized
        }
        try context.save()
        return transition
    }

    func clearAccountData() throws {
        try clearCachedContent()
        try context.fetch(FetchDescriptor<CachedAccountRecord>()).forEach(context.delete)
        try context.save()
    }

    func projects() throws -> [TimenProject] {
        guard try hasAccountBinding() else { return [] }
        let values = try context.fetch(FetchDescriptor<CachedProject>(sortBy: [SortDescriptor(\.name)]))
        return values.map { TimenProject(id: $0.id, name: $0.name, clientName: $0.clientName, isActive: $0.isActive) }
    }

    func replaceProjects(_ projects: [TimenProject]) throws {
        try requireAccountBinding()
        let existing = try context.fetch(FetchDescriptor<CachedProject>())
        existing.forEach(context.delete)
        projects.forEach { context.insert(CachedProject(id: $0.id, name: $0.name, clientName: $0.clientName, isActive: $0.isActive)) }
        try context.save()
    }

    func tags() throws -> [TimenTag] {
        guard try hasAccountBinding() else { return [] }
        return try context.fetch(FetchDescriptor<CachedTag>(sortBy: [SortDescriptor(\.name)]))
            .map { TimenTag(id: $0.id, name: $0.name) }
    }

    func replaceTags(_ tags: [TimenTag]) throws {
        try requireAccountBinding()
        let existing = try context.fetch(FetchDescriptor<CachedTag>())
        existing.forEach(context.delete)
        tags.forEach { context.insert(CachedTag(id: $0.id, name: $0.name)) }
        try context.save()
    }

    func entries(from start: Date, to end: Date) throws -> [TimeEntry] {
        guard try hasAccountBinding() else { return [] }
        let descriptor = FetchDescriptor<CachedEntry>(
            predicate: #Predicate { $0.start >= start && $0.start < end },
            sortBy: [SortDescriptor(\.start, order: .reverse)]
        )
        return try context.fetch(descriptor)
            .filter { $0.syncStateRaw == SyncState.synced.rawValue }
            .map(\.domain)
    }

    func upsertEntries(_ entries: [TimeEntry]) throws {
        try requireAccountBinding()
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

    func replaceEntries(_ entries: [TimeEntry], from start: Date, to end: Date) throws {
        try requireAccountBinding()
        let descriptor = FetchDescriptor<CachedEntry>(predicate: #Predicate {
            $0.start >= start && $0.start < end
        })
        try context.fetch(descriptor).forEach(context.delete)
        try upsertEntries(entries)
    }

    func deleteEntry(id: String) throws {
        try requireAccountBinding()
        let entryID = id
        let descriptor = FetchDescriptor<CachedEntry>(predicate: #Predicate { $0.id == entryID })
        try context.fetch(descriptor).forEach(context.delete)
        try context.save()
    }

    /// One-time compatibility cleanup for stores created by builds that
    /// experimented with queued offline mutations. The legacy model types stay
    /// in the schema so SwiftData can open those stores safely.
    func discardLegacyOfflineMutationState() throws {
        try context.fetch(FetchDescriptor<OutboxRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<ConflictRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<CachedEntry>())
            .filter { $0.syncStateRaw != SyncState.synced.rawValue }
            .forEach(context.delete)
        try context.fetch(FetchDescriptor<PendingSegmentRecord>())
            .filter { $0.remoteTimerID == nil }
            .forEach(context.delete)
        try context.save()
    }

    func favorites() throws -> [Favorite] {
        guard try hasAccountBinding() else { return [] }
        return try context.fetch(FetchDescriptor<FavoriteRecord>(sortBy: [SortDescriptor(\.sortOrder)]))
            .map(\.domain)
    }

    /// Converts legacy "favorite timer" records to project-only favorites,
    /// removes invalid/duplicate projects, and updates names from the current
    /// account's project list. Legacy columns remain in the schema so existing
    /// stores continue to migrate safely.
    @discardableResult
    func reconcileFavorites(with projects: [TimenProject]) throws -> [Favorite] {
        try requireAccountBinding()
        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let records = try context.fetch(FetchDescriptor<FavoriteRecord>(sortBy: [SortDescriptor(\.sortOrder)]))
        var seenProjectIDs = Set<String>()
        var retained: [FavoriteRecord] = []

        for record in records {
            guard let projectID = record.projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !projectID.isEmpty,
                  let project = projectsByID[projectID],
                  seenProjectIDs.insert(projectID).inserted
            else {
                context.delete(record)
                continue
            }
            record.projectID = projectID
            record.name = project.name
            record.tagIDsData = try encoder.encode([String]())
            record.note = ""
            record.billable = true
            record.sortOrder = retained.count
            retained.append(record)
        }
        try context.save()
        return retained.map(\.domain)
    }

    func saveFavorite(_ favorite: Favorite) throws {
        try requireAccountBinding()
        guard let projectID = favorite.projectID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !projectID.isEmpty
        else { throw OfflineStoreError.favoriteRequiresProject }
        let favoriteID = favorite.id
        var descriptor = FetchDescriptor<FavoriteRecord>(predicate: #Predicate { $0.id == favoriteID })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.name = favorite.name
            record.projectID = projectID
            record.tagIDsData = try encoder.encode([String]())
            record.note = ""
            record.billable = true
            record.sortOrder = favorite.sortOrder
        } else {
            var normalized = favorite
            normalized.projectID = projectID
            normalized.tagIDs = []
            normalized.note = ""
            normalized.billable = true
            context.insert(FavoriteRecord(favorite: normalized))
        }
        try context.save()
    }

    func deleteFavorite(id: UUID) throws {
        try requireAccountBinding()
        let favoriteID = id
        let descriptor = FetchDescriptor<FavoriteRecord>(predicate: #Predicate { $0.id == favoriteID })
        try context.fetch(descriptor).forEach(context.delete)
        try context.save()
    }

    func saveSegment(_ segment: ActiveTimerSegment) throws {
        try requireAccountBinding()
        context.insert(PendingSegmentRecord(segment: segment))
        try context.save()
    }

    func activeSegment() throws -> ActiveTimerSegment? {
        guard try hasAccountBinding() else { return nil }
        let descriptor = FetchDescriptor<PendingSegmentRecord>(predicate: #Predicate { $0.endedAt == nil })
        return try context.fetch(descriptor).first?.domain
    }

    func updateActiveSegment(draft: TimerDraft? = nil, remoteTimerID: String? = nil) throws {
        try requireAccountBinding()
        var descriptor = FetchDescriptor<PendingSegmentRecord>(predicate: #Predicate { $0.endedAt == nil })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return }
        if let draft { record.draftData = (try? encoder.encode(draft)) ?? record.draftData }
        if let remoteTimerID { record.remoteTimerID = remoteTimerID }
        try context.save()
    }

    func discardActiveSegment() throws {
        try requireAccountBinding()
        let descriptor = FetchDescriptor<PendingSegmentRecord>(predicate: #Predicate { $0.endedAt == nil })
        try context.fetch(descriptor).forEach(context.delete)
        try context.save()
    }

    private func accountRecord() throws -> CachedAccountRecord? {
        var descriptor = FetchDescriptor<CachedAccountRecord>()
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func hasAccountBinding() throws -> Bool {
        guard let record = try accountRecord() else { return false }
        return !record.accountID.isEmpty && record.domain?.id == record.accountID
    }

    private func requireAccountBinding() throws {
        guard try hasAccountBinding() else { throw OfflineStoreError.accountNotBound }
    }

    private func clearCachedContent() throws {
        try context.fetch(FetchDescriptor<CachedProject>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<CachedTag>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<CachedEntry>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<FavoriteRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<PendingSegmentRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<OutboxRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<ConflictRecord>()).forEach(context.delete)
    }
}
