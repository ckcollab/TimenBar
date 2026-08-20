import SwiftData

enum PersistenceSchema {
    static let models: [any PersistentModel.Type] = [
        CachedAccountRecord.self,
        CachedProject.self,
        CachedTag.self,
        CachedEntry.self,
        FavoriteRecord.self,
        // Retained until a versioned migration can remove pre-release outbox
        // entities without making an existing store (and its favorites) fail.
        OutboxRecord.self,
        ConflictRecord.self,
        PendingSegmentRecord.self,
    ]
}
