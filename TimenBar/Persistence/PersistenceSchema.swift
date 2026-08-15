import SwiftData

enum PersistenceSchema {
    static let models: [any PersistentModel.Type] = [
        CachedProject.self,
        CachedTag.self,
        CachedEntry.self,
        FavoriteRecord.self,
        OutboxRecord.self,
        ConflictRecord.self,
        PendingSegmentRecord.self,
    ]
}

