import Foundation
import SwiftData

@Model
final class CachedAccountRecord {
    @Attribute(.unique) var id: String
    var accountID: String
    var accountData: Data
    var updatedAt: Date

    init(account: TimenAccount) {
        id = "current"
        accountID = account.id
        accountData = (try? JSONEncoder().encode(account)) ?? Data()
        updatedAt = .now
    }

    var domain: TimenAccount? {
        try? JSONDecoder().decode(TimenAccount.self, from: accountData)
    }
}

@Model
final class CachedProject {
    @Attribute(.unique) var id: String
    var name: String
    var clientName: String?
    var isActive: Bool
    var updatedAt: Date

    init(id: String, name: String, clientName: String?, isActive: Bool, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.clientName = clientName
        self.isActive = isActive
        self.updatedAt = updatedAt
    }
}

@Model
final class CachedTag {
    @Attribute(.unique) var id: String
    var name: String
    var updatedAt: Date

    init(id: String, name: String, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
    }
}

@Model
final class CachedEntry {
    @Attribute(.unique) var id: String
    var remoteID: String?
    var start: Date
    var end: Date?
    var projectID: String?
    var projectName: String?
    var clientName: String?
    var note: String
    var tagData: Data
    var billable: Bool
    var syncStateRaw: String
    var updatedAt: Date

    init(entry: TimeEntry) {
        id = entry.id
        remoteID = entry.remoteID
        start = entry.start
        end = entry.end
        projectID = entry.projectID
        projectName = entry.projectName
        clientName = entry.clientName
        note = entry.note
        tagData = (try? JSONEncoder().encode(entry.tags)) ?? Data()
        billable = entry.billable
        syncStateRaw = entry.syncState.rawValue
        updatedAt = .now
    }

    var domain: TimeEntry {
        TimeEntry(
            id: id,
            remoteID: remoteID,
            start: start,
            end: end,
            projectID: projectID,
            projectName: projectName,
            clientName: clientName,
            note: note,
            tags: (try? JSONDecoder().decode([TimenTag].self, from: tagData)) ?? [],
            billable: billable,
            syncState: SyncState(rawValue: syncStateRaw) ?? .synced
        )
    }
}

@Model
final class FavoriteRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var projectID: String?
    var tagIDsData: Data
    var note: String
    var billable: Bool
    var sortOrder: Int

    init(favorite: Favorite) {
        id = favorite.id
        name = favorite.name
        projectID = favorite.projectID
        tagIDsData = (try? JSONEncoder().encode([String]())) ?? Data()
        note = ""
        billable = true
        sortOrder = favorite.sortOrder
    }

    var domain: Favorite {
        Favorite(
            id: id,
            name: name,
            projectID: projectID,
            tagIDs: [],
            note: "",
            billable: true,
            sortOrder: sortOrder
        )
    }
}

@Model
final class OutboxRecord {
    // Legacy schema only. Keeping this model lets pre-release stores open long
    // enough to discard abandoned offline mutations without risking favorites.
    @Attribute(.unique) var id: UUID
    var sequence: Int64
    var kindRaw: String
    var entryID: String?
    var payload: Data
    var stateRaw: String
    var attempts: Int
    var createdAt: Date
    var lastError: String?

    init(
        id: UUID,
        sequence: Int64,
        kindRaw: String,
        entryID: String?,
        payload: Data,
        stateRaw: String,
        attempts: Int,
        createdAt: Date,
        lastError: String?
    ) {
        self.id = id
        self.sequence = sequence
        self.kindRaw = kindRaw
        self.entryID = entryID
        self.payload = payload
        self.stateRaw = stateRaw
        self.attempts = attempts
        self.createdAt = createdAt
        self.lastError = lastError
    }

}

@Model
final class ConflictRecord {
    // Legacy schema only; see OutboxRecord.
    @Attribute(.unique) var id: UUID
    var mutationID: UUID
    var title: String
    var explanation: String
    var localSummary: String
    var remoteSummary: String
    var createdAt: Date

    init(
        id: UUID,
        mutationID: UUID,
        title: String,
        explanation: String,
        localSummary: String,
        remoteSummary: String,
        createdAt: Date
    ) {
        self.id = id
        self.mutationID = mutationID
        self.title = title
        self.explanation = explanation
        self.localSummary = localSummary
        self.remoteSummary = remoteSummary
        self.createdAt = createdAt
    }

}

@Model
final class PendingSegmentRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var draftData: Data
    var remoteTimerID: String?

    init(segment: ActiveTimerSegment) {
        id = segment.id
        startedAt = segment.startedAt
        endedAt = segment.endedAt
        draftData = (try? JSONEncoder().encode(segment.draft)) ?? Data()
        remoteTimerID = segment.remoteTimerID
    }

    var domain: ActiveTimerSegment? {
        guard let draft = try? JSONDecoder().decode(TimerDraft.self, from: draftData) else { return nil }
        return ActiveTimerSegment(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            draft: draft,
            remoteTimerID: remoteTimerID
        )
    }
}
