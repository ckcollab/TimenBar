import Foundation

enum SyncState: String, Codable, CaseIterable, Sendable {
    case synced
    case pending
    case sending
    case conflict
    case failed
}

struct TimenAccount: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var email: String?
    var teamName: String
    var role: String?
    var timeZoneIdentifier: String
}

struct TimenProject: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var clientName: String?
    var isActive: Bool = true

    var displayPath: String {
        if let clientName, !clientName.isEmpty { return "\(clientName) · \(name)" }
        return name
    }
}

struct TimenTag: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
}

struct TimeEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var remoteID: String?
    var start: Date
    var end: Date?
    var projectID: String?
    var projectName: String?
    var clientName: String?
    var note: String
    var tags: [TimenTag]
    var billable: Bool
    var syncState: SyncState

    var duration: TimeInterval {
        max(0, (end ?? .now).timeIntervalSince(start))
    }
}

struct RunningTimer: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var remoteID: String?
    var startedAt: Date
    var projectID: String?
    var projectName: String?
    var clientName: String?
    var note: String
    var tags: [TimenTag]
    var billable: Bool
    var syncState: SyncState

    func elapsed(at date: Date = .now) -> TimeInterval {
        max(0, date.timeIntervalSince(startedAt))
    }
}

struct TimerDraft: Codable, Hashable, Sendable {
    var projectID: String?
    var tagIDs: [String]
    var note: String
    var billable: Bool

    static let empty = TimerDraft(projectID: nil, tagIDs: [], note: "", billable: false)
}

struct Favorite: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var projectID: String?
    var tagIDs: [String]
    var note: String
    var billable: Bool
    var sortOrder: Int
}

enum OutboxMutationKind: String, Codable, Sendable {
    case startTimer
    case stopTimer
    case logTime
    case updateEntry
    case deleteEntry
}

enum OutboxMutationState: String, Codable, Sendable {
    case pending
    case sending
    case applied
    case needsReview
    case failed
}

struct QueuedMutation: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var sequence: Int64
    var kind: OutboxMutationKind
    var entryID: String?
    var payload: Data
    var state: OutboxMutationState
    var attempts: Int
    var createdAt: Date
    var lastError: String?
}

struct PendingTimerSegment: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var draft: TimerDraft
    var remoteTimerID: String?
}

struct StartTimerPayload: Codable, Hashable, Sendable {
    var draft: TimerDraft
    var requestedAt: Date
}

struct StopTimerPayload: Codable, Hashable, Sendable {
    var timer: RunningTimer
    var desiredEnd: Date
}

struct LogTimePayload: Codable, Hashable, Sendable {
    var localEntryID: String
    var start: Date
    var end: Date
    var draft: TimerDraft
}

struct UpdateEntryPayload: Codable, Hashable, Sendable {
    var entryID: String
    var draft: TimerDraft
    var start: Date?
    var end: Date?
    var baseSummary: String
}

struct DeleteEntryPayload: Codable, Hashable, Sendable {
    var entryID: String
    var baseSummary: String
}

struct SyncConflict: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var mutationID: UUID
    var title: String
    var explanation: String
    var localSummary: String
    var remoteSummary: String
    var createdAt: Date
}

enum ConflictDecision: Sendable {
    case keepLocal
    case keepTimen
}

struct DaySummary: Hashable, Identifiable, Sendable {
    var date: Date
    var duration: TimeInterval
    var isToday: Bool

    var id: Date { date }
}

enum IdleResolution: Sendable {
    case keepAndStop
    case removeIdleAndStop(idleStartedAt: Date)
    case deleteEntry
    case continueWorking
}

enum TimenBarError: LocalizedError, Sendable {
    case notAuthenticated
    case incompatibleServer(missingTools: [String])
    case networkUnavailable
    case invalidResponse(String)
    case oauth(String)
    case conflict(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Sign in to Timen first."
        case let .incompatibleServer(tools): "Timen is missing required tools: \(tools.joined(separator: ", "))."
        case .networkUnavailable: "Timen is currently unreachable. The change was queued."
        case let .invalidResponse(message): "Timen returned an unexpected response: \(message)"
        case let .oauth(message): "Sign-in failed: \(message)"
        case let .conflict(message): "This change needs review: \(message)"
        }
    }
}

extension TimeInterval {
    var timerText: String {
        let totalMinutes = max(0, Int(self) / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return String(format: "%d:%02d", hours, minutes)
    }

    var statusTimerText: String {
        let totalSeconds = max(0, Int(self))
        return String(format: "%02d:%02d", totalSeconds / 3600, (totalSeconds % 3600) / 60)
    }
}
