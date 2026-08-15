import Foundation
import MCP
import OSLog

private final class BearerTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String = ""

    func update(_ token: String) {
        lock.lock()
        value = token
        lock.unlock()
    }

    func authorize(_ request: URLRequest) -> URLRequest {
        lock.lock()
        let token = value
        lock.unlock()
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

actor TimenMCPGateway: TimenGateway {
    private let logger = Logger(subsystem: "app.timenbar.TimenBar", category: "MCP")
    private let oauth: OAuthSession
    private let tokenBox = BearerTokenBox()
    private var client: Client?
    private var transport: HTTPClientTransport?
    private var schemas: [String: Value] = [:]
    private var currentAccountID: String?
    private var knownTagNames: [String: String] = [:]

    init(oauth: OAuthSession = OAuthSession()) {
        self.oauth = oauth
    }

    func isAuthenticated() async -> Bool { await oauth.isAuthenticated() }

    func authenticate() async throws {
        try await oauth.authenticate()
        try await connectIfNeeded()
        try await validateCapabilities()
    }

    func signOut() async throws {
        await client?.disconnect()
        client = nil
        transport = nil
        schemas = [:]
        try await oauth.signOut()
    }

    func validateCapabilities() async throws {
        let client = try await connectedClient()
        var names = Set<String>()
        var cursor: String?
        repeat {
            let page = try await client.listTools(cursor: cursor)
            for tool in page.tools {
                names.insert(tool.name)
                schemas[tool.name] = tool.inputSchema
            }
            cursor = page.nextCursor
        } while cursor != nil

        let missing = TimenToolContract.missing(from: names)
        guard missing.isEmpty else { throw TimenBarError.incompatibleServer(missingTools: missing) }
#if DEBUG
        for name in ["timen_start_timer", "timen_stop_timer", "timen_update_time_entry", "timen_delete_time_entry"] {
            if let schema = schemas[name] {
                logger.debug("schema \(name, privacy: .public)=\(Self.logJSONValue(schema), privacy: .public)")
            }
        }
#endif
    }

    func account() async throws -> TimenAccount {
        let value = try await call("timen_get_me")
        let root = value.firstObject(keys: ["data"]) ?? value
        let object = root.firstObject(keys: ["user", "me", "account"]) ?? root
        let account = TimenAccount(
            id: object.string(keys: ["id", "user_id"]) ?? "me",
            name: object.string(keys: ["name", "full_name"]) ?? "Timen user",
            email: object.string(keys: ["email"]),
            teamName: object.string(keys: ["team_name", "team", "workspace_name"]) ?? "Timen",
            role: object.string(keys: ["role"]),
            timeZoneIdentifier: object.string(keys: ["time_zone", "timezone", "timeZone"]) ?? TimeZone.current.identifier
        )
        currentAccountID = account.id == "me" ? nil : account.id
        return account
    }

    func runningTimer() async throws -> RunningTimer? {
        let value = try await call("timen_get_running_timer")
        let candidate = value.firstValue(keys: ["timer", "running_timer", "runningTimer", "data"]) ?? value
        if candidate == .null { return nil }
        guard let startedAt = candidate.date(keys: ["started_at", "start", "start_time", "startedAt"]) else { return nil }
        let project = candidate.firstObject(keys: ["project"])
        return RunningTimer(
            id: candidate.string(keys: ["id", "timer_id"]) ?? "remote-running",
            remoteID: candidate.string(keys: ["id", "timer_id"]),
            startedAt: startedAt,
            projectID: candidate.string(keys: ["project_id", "projectId"]) ?? project?.string(keys: ["id"]),
            projectName: candidate.string(keys: ["project_name"]) ?? project?.string(keys: ["name"]),
            clientName: candidate.string(keys: ["client_name"]) ?? project?.string(keys: ["client_name"]),
            note: candidate.string(keys: ["note", "description"]) ?? "",
            tags: parseTags(candidate.firstValue(keys: ["tags"])),
            billable: candidate.bool(keys: ["billable", "is_billable"]) ?? false,
            syncState: .synced
        )
    }

    func projects() async throws -> [TimenProject] {
        let value = try await call("timen_list_projects")
        return value.array(keys: ["projects", "data"]).map { item in
            let client = item.firstObject(keys: ["client"])
            return TimenProject(
                id: item.string(keys: ["id", "project_id"]) ?? UUID().uuidString,
                name: item.string(keys: ["name", "project_name"]) ?? "Untitled project",
                clientName: item.string(keys: ["client_name"]) ?? client?.string(keys: ["name"]),
                isActive: !(item.bool(keys: ["archived", "is_archived"]) ?? false)
            )
        }
    }

    func tags() async throws -> [TimenTag] {
        let tags = parseTags(try await call("timen_list_tags"))
        knownTagNames = tags.reduce(into: [:]) { $0[$1.id] = $1.name }
        return tags
    }

    func entries(from: Date, to: Date) async throws -> [TimeEntry] {
        var filters = [
            SemanticArgument(names: ["start_date", "from", "start", "from_date"], value: .string(Self.dayString(from))),
            SemanticArgument(names: ["end_date", "to", "end", "to_date"], value: .string(Self.dayString(to))),
        ]
        if let currentAccountID {
            let identifierValue = Self.identifierValue(currentAccountID)
            filters.append(SemanticArgument(
                names: ["user_id", "member_id", "person_id", "owner_id"],
                value: identifierValue
            ))
            filters.append(SemanticArgument(
                names: ["user_ids", "member_ids", "person_ids", "owner_ids"],
                value: .array([identifierValue])
            ))
        }
        let arguments = arguments(for: "timen_list_time_entries", values: filters)
        let value = try await call("timen_list_time_entries", arguments: arguments)
        return value.array(keys: ["time_entries", "entries", "data"])
            .filter(belongsToCurrentUser)
            .compactMap(parseEntry)
    }

    func startTimer(_ draft: TimerDraft) async throws -> RunningTimer {
        let value = try await call("timen_start_timer", arguments: draftArguments(draft, tool: "timen_start_timer"))
        let candidate = value.firstValue(keys: ["timer", "running_timer", "data"]) ?? value
        let project = candidate.firstObject(keys: ["project"])
        return RunningTimer(
            id: candidate.string(keys: ["id", "timer_id"]) ?? UUID().uuidString,
            remoteID: candidate.string(keys: ["id", "timer_id"]),
            startedAt: candidate.date(keys: ["started_at", "start", "start_time"]) ?? .now,
            projectID: candidate.string(keys: ["project_id"]) ?? draft.projectID,
            projectName: candidate.string(keys: ["project_name"]) ?? project?.string(keys: ["name"]),
            clientName: candidate.string(keys: ["client_name"]) ?? project?.string(keys: ["client_name"]),
            note: candidate.string(keys: ["note", "description"]) ?? draft.note,
            tags: parseTags(candidate.firstValue(keys: ["tags"])),
            billable: candidate.bool(keys: ["billable"]) ?? draft.billable,
            syncState: .synced
        )
    }

    func stopTimer() async throws -> TimeEntry {
        let value = try await call("timen_stop_timer")
        let candidate = value.firstValue(keys: ["time_entry", "entry", "timer", "data"]) ?? value
        guard let entry = parseEntry(candidate) else { throw TimenBarError.invalidResponse("Stopped timer did not include an entry.") }
        return entry
    }

    func logTime(start: Date, end: Date, draft: TimerDraft) async throws -> TimeEntry {
        var values = draftSemanticArguments(draft)
        values += [
            SemanticArgument(names: ["start", "started_at", "start_time"], value: .string(Self.dateString(start))),
            SemanticArgument(names: ["end", "ended_at", "end_time"], value: .string(Self.dateString(end))),
        ]
        let value = try await call("timen_log_time", arguments: arguments(for: "timen_log_time", values: values))
        let candidate = value.firstValue(keys: ["time_entry", "entry", "data"]) ?? value
        guard let entry = parseEntry(candidate) else { throw TimenBarError.invalidResponse("Logged time did not include an entry.") }
        return entry
    }

    func updateEntry(id: String, draft: TimerDraft, start: Date?, end: Date?) async throws -> TimeEntry {
        var values = draftSemanticArguments(draft)
        values.append(SemanticArgument(names: ["time_entry_id", "entry_id", "id"], value: Self.identifierValue(id)))
        if let start { values.append(SemanticArgument(names: ["start", "started_at", "start_time"], value: .string(Self.dateString(start)))) }
        if let end { values.append(SemanticArgument(names: ["end", "ended_at", "end_time"], value: .string(Self.dateString(end)))) }
        let value = try await call("timen_update_time_entry", arguments: arguments(for: "timen_update_time_entry", values: values))
        let candidate = value.firstValue(keys: ["time_entry", "entry", "data"]) ?? value
        guard let entry = parseEntry(candidate) else { throw TimenBarError.invalidResponse("Updated entry was missing from the response.") }
        return entry
    }

    func updateEntryDuration(id: String, draft: TimerDraft, duration: TimeInterval) async throws -> TimeEntry {
        var values = draftSemanticArguments(draft)
        values.append(SemanticArgument(names: ["time_entry_id", "entry_id", "id"], value: Self.identifierValue(id)))
        values.append(SemanticArgument(names: ["duration"], value: .int(max(0, Int(duration.rounded())))))
        let value = try await call(
            "timen_update_time_entry",
            arguments: arguments(for: "timen_update_time_entry", values: values)
        )
        let candidate = value.firstValue(keys: ["time_entry", "entry", "data"]) ?? value
        guard let entry = parseEntry(candidate) else {
            throw TimenBarError.invalidResponse("Updated entry was missing from the response.")
        }
        return entry
    }

    func deleteEntry(id: String) async throws {
        let response = try await call(
            "timen_delete_time_entry",
            arguments: arguments(for: "timen_delete_time_entry", values: [
                SemanticArgument(names: ["time_entry_id", "entry_id", "id"], value: Self.identifierValue(id)),
                SemanticArgument(names: ["confirm"], value: .bool(true)),
            ])
        )
        if response.bool(keys: ["deleted"]) == false {
            throw TimenBarError.invalidResponse(
                response.string(keys: ["message"]) ?? "Timen did not confirm that the entry was deleted."
            )
        }
    }

    private func connectedClient() async throws -> Client {
        try await connectIfNeeded()
        guard let client else { throw TimenBarError.notAuthenticated }
        return client
    }

    private func connectIfNeeded() async throws {
        let token = try await oauth.accessToken()
        tokenBox.update(token)
        guard client == nil else { return }

        let transport = HTTPClientTransport(
            endpoint: OAuthSession.resourceURL,
            streaming: false,
            requestModifier: { [tokenBox] request in tokenBox.authorize(request) }
        )
        let client = Client(name: "TimenBar", version: "0.1.0")
        try await client.connect(transport: transport)
        self.transport = transport
        self.client = client
    }

    private func call(_ name: String, arguments: [String: Value]? = nil) async throws -> Value {
        let traceID = String(UUID().uuidString.prefix(8))
#if DEBUG
        logger.debug("[\(traceID, privacy: .public)] → \(name, privacy: .public) args=\(Self.logJSON(arguments ?? [:]), privacy: .public)")
#endif
        let token = try await oauth.accessToken()
        tokenBox.update(token)
        let client = try await connectedClient()
        let result: (content: [Tool.Content], isError: Bool?)
        do {
            result = try await client.callTool(name: name, arguments: arguments)
        } catch {
#if DEBUG
            logger.error("[\(traceID, privacy: .public)] ← \(name, privacy: .public) transport-error=\(error.localizedDescription, privacy: .public)")
#endif
            throw error
        }
        if result.isError == true {
            let message = result.content.compactMap { content -> String? in
                if case let .text(text) = content { return text }
                return nil
            }.joined(separator: "\n")
#if DEBUG
            logger.error("[\(traceID, privacy: .public)] ← \(name, privacy: .public) tool-error=\(Self.truncated(message), privacy: .public)")
#endif
            throw TimenBarError.invalidResponse(message)
        }
        let text = result.content.compactMap { content -> String? in
            if case let .text(text) = content { return text }
            return nil
        }.joined(separator: "\n")
#if DEBUG
        logger.debug("[\(traceID, privacy: .public)] ← \(name, privacy: .public) response=\(Self.truncated(text), privacy: .public)")
#endif
        guard !text.isEmpty else { return .object([:]) }
        if let value = Self.decodeValue(text) { return value }
        return .object(["message": .string(text)])
    }

    private func draftArguments(_ draft: TimerDraft, tool: String) -> [String: Value] {
        arguments(for: tool, values: draftSemanticArguments(draft))
    }

    private func draftSemanticArguments(_ draft: TimerDraft) -> [SemanticArgument] {
        var values: [SemanticArgument] = [
            SemanticArgument(names: ["note", "description"], value: .string(draft.note)),
            SemanticArgument(names: ["billable", "is_billable"], value: .bool(true)),
            SemanticArgument(names: ["tag_ids", "tagIds"], value: .array(draft.tagIDs.map(Self.identifierValue))),
            SemanticArgument(
                names: ["tags"],
                value: .array(draft.tagIDs.map { .string(knownTagNames[$0] ?? $0) })
            ),
        ]
        if let projectID = draft.projectID {
            values.append(SemanticArgument(names: ["project_id", "projectId", "project"], value: Self.identifierValue(projectID)))
        }
        return values
    }

    private func arguments(for tool: String, values: [SemanticArgument]) -> [String: Value] {
        let propertyNames: Set<String>
        if let keys = schemas[tool]?.objectValue?["properties"]?.objectValue?.keys {
            propertyNames = Set(keys)
        } else {
            propertyNames = []
        }
        return values.reduce(into: [:]) { output, semantic in
            let key = semantic.names.first(where: propertyNames.contains)
                ?? (propertyNames.isEmpty ? semantic.names.first : nil)
            if let key {
                output[key] = semantic.value
            }
        }
    }

    private func belongsToCurrentUser(_ value: Value) -> Bool {
        guard let currentAccountID else { return true }
        let owner = value.firstObject(keys: ["user", "member", "person", "owner", "employee"])
        let ownerID = value.string(keys: ["user_id", "member_id", "person_id", "owner_id", "employee_id"])
            ?? owner?.string(keys: ["id", "user_id"])
        guard let ownerID else {
            // If Timen omits owner metadata, the schema-level user filter remains authoritative.
            return true
        }
        return ownerID == currentAccountID
    }

    private func parseEntry(_ value: Value) -> TimeEntry? {
        guard let start = value.date(keys: ["start", "started_at", "start_time", "startedAt", "date", "entry_date"]) else { return nil }
        let explicitEnd = value.date(keys: ["end", "ended_at", "end_time", "endedAt"])
        let parsedDuration = TimenDurationParser.duration(from: value)
        let end = explicitEnd ?? parsedDuration.map { start.addingTimeInterval($0) } ?? start
        let project = value.firstObject(keys: ["project"])
        let remoteID = value.string(keys: ["id", "time_entry_id", "entry_id"])
        return TimeEntry(
            id: remoteID ?? UUID().uuidString,
            remoteID: remoteID,
            start: start,
            end: end,
            projectID: value.string(keys: ["project_id", "projectId"]) ?? project?.string(keys: ["id"]),
            projectName: value.string(keys: ["project_name"]) ?? project?.string(keys: ["name"]),
            clientName: value.string(keys: ["client_name"]) ?? project?.string(keys: ["client_name"]),
            note: value.string(keys: ["note", "description"]) ?? "",
            tags: parseTags(value.firstValue(keys: ["tags"])),
            billable: value.bool(keys: ["billable", "is_billable"]) ?? false,
            syncState: .synced
        )
    }

    private func parseTags(_ value: Value?) -> [TimenTag] {
        guard let value else { return [] }
        return value.array(keys: ["tags", "data"]).compactMap { item in
            if let name = item.stringValue { return TimenTag(id: name, name: name) }
            guard let name = item.string(keys: ["name", "tag_name"]) else { return nil }
            return TimenTag(id: item.string(keys: ["id", "tag_id"]) ?? name, name: name)
        }
    }

    private static func decodeValue(_ text: String) -> Value? {
        if let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(Value.self, from: data) { return value }
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = text.lastIndex(where: { $0 == "}" || $0 == "]" }), start <= end,
              let data = String(text[start ... end]).data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private static func identifierValue(_ raw: String) -> Value {
        Int(raw).map(Value.int) ?? .string(raw)
    }

    private static func logJSON(_ value: [String: Value]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "<unencodable>" }
        return truncated(text)
    }

    private static func logJSONValue(_ value: Value) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "<unencodable>" }
        return truncated(text)
    }

    private static func truncated(_ text: String, limit: Int = 16_000) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…<truncated>"
    }

    fileprivate static func dateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    fileprivate static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private struct SemanticArgument {
    var names: [String]
    var value: Value
}

enum TimenDurationParser {
    private static let secondKeys = [
        "duration_seconds", "duration_in_seconds", "elapsed_seconds", "tracked_seconds",
        "total_seconds", "seconds", "duration", "elapsed", "time_spent", "total_time",
    ]
    private static let minuteKeys = ["duration_minutes", "minutes", "total_minutes"]
    private static let hourKeys = ["duration_hours", "hours", "total_hours"]
    private static let formattedKeys = ["formatted_duration", "duration_formatted", "duration_display"]

    static func duration(from value: Value) -> TimeInterval? {
        for key in secondKeys {
            if let result = numericOrClock(value.firstValue(keys: [key]), multiplier: 1) { return result }
        }
        for key in minuteKeys {
            if let result = numericOrClock(value.firstValue(keys: [key]), multiplier: 60) { return result }
        }
        for key in hourKeys {
            if let result = numericOrClock(value.firstValue(keys: [key]), multiplier: 3_600) { return result }
        }
        for key in formattedKeys {
            if let raw = value.firstValue(keys: [key])?.stringValue, let result = parseClock(raw) { return result }
        }
        if let durationObject = value.firstObject(keys: ["duration", "time", "totals"]) {
            return duration(from: durationObject)
        }
        return nil
    }

    static func parseClock(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = Double(trimmed), trimmed.contains(":") == false { return max(0, number) }
        let parts = trimmed.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 2 { return max(0, parts[0] * 3_600 + parts[1] * 60) }
        return max(0, parts[0] * 3_600 + parts[1] * 60 + parts[2])
    }

    private static func numericOrClock(_ value: Value?, multiplier: Double) -> TimeInterval? {
        guard let value else { return nil }
        if let int = value.intValue { return max(0, Double(int) * multiplier) }
        if let double = value.doubleValue { return max(0, double * multiplier) }
        if let string = value.stringValue {
            if string.contains(":") { return parseClock(string) }
            if let number = Double(string) { return max(0, number * multiplier) }
        }
        return nil
    }
}

private extension Value {
    func firstValue(keys: [String]) -> Value? {
        guard let object = objectValue else { return nil }
        for key in keys where object[key] != nil { return object[key] }
        return nil
    }

    func firstObject(keys: [String]) -> Value? {
        guard let value = firstValue(keys: keys) else { return nil }
        if value.objectValue != nil { return value }
        return nil
    }

    func string(keys: [String]) -> String? {
        guard let value = firstValue(keys: keys) else { return nil }
        if let string = value.stringValue { return string }
        if let int = value.intValue { return String(int) }
        return nil
    }

    func bool(keys: [String]) -> Bool? {
        guard let value = firstValue(keys: keys) else { return nil }
        if let bool = value.boolValue { return bool }
        if let int = value.intValue { return int != 0 }
        return nil
    }

    func date(keys: [String]) -> Date? {
        guard let raw = string(keys: keys) else { return nil }
        return TimenMCPGateway.parseDate(raw)
    }

    func array(keys: [String]) -> [Value] {
        if let arrayValue { return arrayValue }
        for key in keys {
            if let nested = firstValue(keys: [key]) {
                if let array = nested.arrayValue { return array }
                if let nestedArray = nested.firstValue(keys: keys)?.arrayValue { return nestedArray }
            }
        }
        return []
    }
}
