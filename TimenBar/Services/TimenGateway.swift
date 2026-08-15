import Foundation

protocol TimenGateway: Sendable {
    func isAuthenticated() async -> Bool
    func authenticate() async throws
    func signOut() async throws
    func validateCapabilities() async throws
    func account() async throws -> TimenAccount
    func runningTimer() async throws -> RunningTimer?
    func projects() async throws -> [TimenProject]
    func tags() async throws -> [TimenTag]
    func entries(from: Date, to: Date) async throws -> [TimeEntry]
    func startTimer(_ draft: TimerDraft) async throws -> RunningTimer
    func stopTimer() async throws -> TimeEntry
    func logTime(start: Date, end: Date, draft: TimerDraft) async throws -> TimeEntry
    func updateEntry(id: String, draft: TimerDraft, start: Date?, end: Date?) async throws -> TimeEntry
    func deleteEntry(id: String) async throws
}

enum RequiredTimenTool {
    static let names: Set<String> = [
        "timen_get_me",
        "timen_get_running_timer",
        "timen_list_projects",
        "timen_list_tags",
        "timen_list_time_entries",
        "timen_start_timer",
        "timen_stop_timer",
        "timen_log_time",
        "timen_update_time_entry",
        "timen_delete_time_entry",
    ]
}

enum TimenToolContract {
    static func missing(from advertised: Set<String>) -> [String] {
        RequiredTimenTool.names.subtracting(advertised).sorted()
    }
}
