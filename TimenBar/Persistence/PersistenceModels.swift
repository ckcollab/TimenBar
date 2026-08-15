import Foundation
import SwiftData

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
        tagIDsData = (try? JSONEncoder().encode(favorite.tagIDs)) ?? Data()
        note = favorite.note
        billable = favorite.billable
        sortOrder = favorite.sortOrder
    }

    var domain: Favorite {
        Favorite(
            id: id,
            name: name,
            projectID: projectID,
            tagIDs: (try? JSONDecoder().decode([String].self, from: tagIDsData)) ?? [],
            note: note,
            billable: billable,
            sortOrder: sortOrder
        )
    }
}

@Model
final class OutboxRecord {
    @Attribute(.unique) var id: UUID
    var sequence: Int64
    var kindRaw: String
    var entryID: String?
    var payload: Data
    var stateRaw: String
    var attempts: Int
    var createdAt: Date
    var lastError: String?

    init(mutation: QueuedMutation) {
        id = mutation.id
        sequence = mutation.sequence
        kindRaw = mutation.kind.rawValue
        entryID = mutation.entryID
        payload = mutation.payload
        stateRaw = mutation.state.rawValue
        attempts = mutation.attempts
        createdAt = mutation.createdAt
        lastError = mutation.lastError
    }

    var domain: QueuedMutation? {
        guard let kind = OutboxMutationKind(rawValue: kindRaw),
              let state = OutboxMutationState(rawValue: stateRaw)
        else { return nil }
        return QueuedMutation(
            id: id,
            sequence: sequence,
            kind: kind,
            entryID: entryID,
            payload: payload,
            state: state,
            attempts: attempts,
            createdAt: createdAt,
            lastError: lastError
        )
    }
}

@Model
final class ConflictRecord {
    @Attribute(.unique) var id: UUID
    var mutationID: UUID
    var title: String
    var explanation: String
    var localSummary: String
    var remoteSummary: String
    var createdAt: Date

    init(conflict: SyncConflict) {
        id = conflict.id
        mutationID = conflict.mutationID
        title = conflict.title
        explanation = conflict.explanation
        localSummary = conflict.localSummary
        remoteSummary = conflict.remoteSummary
        createdAt = conflict.createdAt
    }

    var domain: SyncConflict {
        SyncConflict(
            id: id,
            mutationID: mutationID,
            title: title,
            explanation: explanation,
            localSummary: localSummary,
            remoteSummary: remoteSummary,
            createdAt: createdAt
        )
    }
}

@Model
final class PendingSegmentRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var draftData: Data
    var remoteTimerID: String?

    init(segment: PendingTimerSegment) {
        id = segment.id
        startedAt = segment.startedAt
        endedAt = segment.endedAt
        draftData = (try? JSONEncoder().encode(segment.draft)) ?? Data()
        remoteTimerID = segment.remoteTimerID
    }

    var domain: PendingTimerSegment? {
        guard let draft = try? JSONDecoder().decode(TimerDraft.self, from: draftData) else { return nil }
        return PendingTimerSegment(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            draft: draft,
            remoteTimerID: remoteTimerID
        )
    }
}

