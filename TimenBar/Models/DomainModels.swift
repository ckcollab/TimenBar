import Foundation

enum SyncState: String, Codable, Sendable {
    case synced
}

enum TimenTheme: String, Codable, CaseIterable, Sendable {
    case standard = "default"
    case blue
    case purple
    case orange

    static let fallback: TimenTheme = .standard

    init?(mcpValue: String) {
        self.init(rawValue: mcpValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var displayName: String {
        switch self {
        case .standard: "Default"
        default: rawValue.capitalized
        }
    }
}

struct TimenAccount: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var email: String?
    var teamName: String
    var role: String?
    var timeZoneIdentifier: String
    var theme: TimenTheme? = nil

    var effectiveTheme: TimenTheme { theme ?? .fallback }
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

    /// Timen's integer entry IDs increase as entries are created. Using that
    /// immutable sequence keeps edits and timer transitions from moving rows.
    static func newestCreatedFirst(_ lhs: TimeEntry, _ rhs: TimeEntry) -> Bool {
        if let leftID = lhs.remoteID.flatMap(Int64.init),
           let rightID = rhs.remoteID.flatMap(Int64.init),
           leftID != rightID
        {
            return leftID > rightID
        }
        if lhs.start != rhs.start { return lhs.start > rhs.start }
        return lhs.id > rhs.id
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

    static let empty = TimerDraft(projectID: nil, tagIDs: [], note: "", billable: true)

    var enforcingBillable: TimerDraft {
        var copy = self
        copy.billable = true
        return copy
    }
}

enum TimerDurationInput {
    static func parse(_ text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty,
              components[0].allSatisfy(\.isNumber),
              components[1].allSatisfy(\.isNumber),
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              minutes < 60,
              hours <= (Int.max - minutes * 60) / 3_600
        else { return nil }

        return TimeInterval(hours * 3_600 + minutes * 60)
    }

    static func format(_ duration: TimeInterval) -> String {
        duration.timerText
    }
}

enum TimerDateChange {
    static func ending(
        at referenceEnd: Date,
        duration: TimeInterval,
        on selectedDate: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        var components = calendar.dateComponents([.year, .month, .day], from: selectedDate)
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: referenceEnd)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        components.nanosecond = time.nanosecond

        let shiftedEnd = calendar.date(from: components) ?? referenceEnd
        let duration = max(0, duration)
        let preferredStart = shiftedEnd.addingTimeInterval(-duration)
        let selectedDayStart = calendar.startOfDay(for: selectedDate)

        // The composer's Date represents the entry's start date. If subtracting
        // a long duration would move the start into the previous day, anchor the
        // entry at midnight and let its end move forward instead.
        guard preferredStart >= selectedDayStart else {
            return (selectedDayStart, selectedDayStart.addingTimeInterval(duration))
        }
        return (preferredStart, shiftedEnd)
    }

    static func shifting(
        start: Date,
        end: Date,
        to selectedDate: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        shifting(
            start: start,
            duration: max(0, end.timeIntervalSince(start)),
            to: selectedDate,
            calendar: calendar
        )
    }

    static func shifting(
        start: Date,
        duration: TimeInterval,
        to selectedDate: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date) {
        var components = calendar.dateComponents([.year, .month, .day], from: selectedDate)
        let time = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: start)
        components.hour = time.hour
        components.minute = time.minute
        components.second = time.second
        components.nanosecond = time.nanosecond

        guard let shiftedStart = calendar.date(from: components) else {
            return (start, start.addingTimeInterval(max(0, duration)))
        }
        return (shiftedStart, shiftedStart.addingTimeInterval(max(0, duration)))
    }
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

struct ActiveTimerSegment: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var draft: TimerDraft
    var remoteTimerID: String?
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
        case .networkUnavailable: "Timen is currently unreachable. Check your connection and try again."
        case let .invalidResponse(message): "Timen returned an unexpected response: \(message)"
        case let .oauth(message): "Sign-in failed: \(message)"
        case let .conflict(message): "Timen rejected the change: \(message)"
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
