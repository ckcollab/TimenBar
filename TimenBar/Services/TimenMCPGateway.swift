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
    private var currentAccountRole: String?
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
        currentAccountID = nil
        currentAccountRole = nil
        knownTagNames = [:]
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
        try TimenMCPMutationContract.validateBillableSupport(in: schemas)
#if DEBUG
        for name in ["timen_start_timer", "timen_stop_timer", "timen_update_time_entry", "timen_delete_time_entry"] {
            if let schema = schemas[name] {
                logger.debug("schema \(name, privacy: .public)=\(Self.logJSONValue(schema), privacy: .public)")
            }
        }
#endif
    }

    func account() async throws -> TimenAccount {
        currentAccountID = nil
        currentAccountRole = nil
        let value = try await call("timen_get_me")
        let account = try TimenMCPResponseParser.account(from: value)
        currentAccountID = account.id
        currentAccountRole = TimenMCPEntryScope.normalizedRole(account.role)
        return account
    }

    func runningTimer() async throws -> RunningTimer? {
        let value = try await call("timen_get_running_timer")
        return try TimenMCPResponseParser.runningTimer(from: value)
    }

    func projects() async throws -> [TimenProject] {
        let value = try await call("timen_list_projects")
        return try TimenMCPResponseParser.projects(from: value)
    }

    func tags() async throws -> [TimenTag] {
        let tags = try TimenMCPResponseParser.tagList(from: try await call("timen_list_tags"))
        knownTagNames = tags.reduce(into: [:]) { $0[$1.id] = $1.name }
        return tags
    }

    func entries(from: Date, to: Date) async throws -> [TimeEntry] {
        guard let currentAccountID else {
            throw TimenBarError.invalidResponse(
                "Cannot verify time-entry ownership because Timen did not provide a current account ID."
            )
        }
        var filters = [
            SemanticArgument(names: ["start_date", "from", "start", "from_date"], value: .string(Self.dayString(from))),
            SemanticArgument(names: ["end_date", "to", "end", "to_date"], value: .string(Self.dayString(to))),
        ]
        filters += TimenMCPEntryScope.userFilterArguments(
            accountIdentifier: Self.identifierValue(currentAccountID),
            normalizedRole: currentAccountRole
        )
        let arguments = arguments(for: "timen_list_time_entries", values: filters)
        let userFilterWasEmitted = emittedRecognizedArgument(
            for: "timen_list_time_entries",
            arguments: arguments,
            names: TimenMCPResponseParser.userFilterArgumentNames
        )
        let requestWasCurrentUserScoped = userFilterWasEmitted
            || TimenMCPEntryScope.unfilteredRequestIsCurrentUserScoped(normalizedRole: currentAccountRole)
        let value = try await call("timen_list_time_entries", arguments: arguments)
        return try TimenMCPResponseParser.entries(
            from: value,
            currentAccountID: currentAccountID,
            requestWasCurrentUserScoped: requestWasCurrentUserScoped
        )
    }

    func startTimer(_ draft: TimerDraft) async throws -> RunningTimer {
        let value = try await call(
            "timen_start_timer",
            arguments: try draftArguments(draft, tool: "timen_start_timer")
        )
        let candidate = value.firstValue(keys: ["timer", "running_timer", "data"]) ?? value
        let project = candidate.firstObject(keys: ["project"])
        guard let remoteID = TimenMCPResponseParser.identifier(in: candidate, keys: ["id", "timer_id"]) else {
            throw TimenBarError.invalidResponse("Started timer did not include a stable timer ID.")
        }
        guard let startedAt = candidate.date(keys: ["started_at", "start", "start_time"]) else {
            throw TimenBarError.invalidResponse("Started timer did not include a valid start time.")
        }
        let projectID = TimenMCPResponseParser.identifier(in: candidate, keys: ["project_id", "projectId"])
            ?? project.flatMap { TimenMCPResponseParser.identifier(in: $0, keys: ["id", "project_id"]) }
            ?? draft.projectID
        if project != nil, projectID == nil {
            throw TimenBarError.invalidResponse("Started timer included a project without a stable project ID.")
        }
        return RunningTimer(
            id: remoteID,
            remoteID: remoteID,
            startedAt: startedAt,
            projectID: projectID,
            projectName: candidate.string(keys: ["project_name"]) ?? project?.string(keys: ["name"]),
            clientName: candidate.string(keys: ["client_name"]) ?? project?.string(keys: ["client_name"]),
            note: candidate.string(keys: ["note", "description"]) ?? draft.note,
            tags: TimenMCPResponseParser.embeddedTags(from: candidate.firstValue(keys: ["tags"])),
            billable: candidate.bool(keys: ["billable"]) ?? draft.billable,
            syncState: .synced
        )
    }

    func stopTimer() async throws -> TimeEntry {
        let value = try await call("timen_stop_timer")
        let candidate = value.firstValue(keys: ["time_entry", "entry", "timer", "data"]) ?? value
        return try TimenMCPResponseParser.entry(from: candidate)
    }

    func logTime(start: Date, end: Date, draft: TimerDraft) async throws -> TimeEntry {
        let arguments = try draftArguments(draft, tool: "timen_log_time", additionalValues: [
            SemanticArgument(names: ["start", "started_at", "start_time"], value: .string(Self.dateString(start))),
            SemanticArgument(names: ["end", "ended_at", "end_time"], value: .string(Self.dateString(end))),
        ])
        let value = try await call("timen_log_time", arguments: arguments)
        let candidate = value.firstValue(keys: ["time_entry", "entry", "data"]) ?? value
        return try TimenMCPResponseParser.entry(from: candidate)
    }

    func updateEntry(id: String, draft: TimerDraft, start: Date?, end: Date?) async throws -> TimeEntry {
        var additionalValues = [
            SemanticArgument(names: ["time_entry_id", "entry_id", "id"], value: Self.identifierValue(id)),
        ]
        additionalValues += TimenMCPUpdateTiming.arguments(start: start, end: end)
        let arguments = try draftArguments(
            draft,
            tool: "timen_update_time_entry",
            additionalValues: additionalValues
        )
        try TimenMCPUpdateTiming.validateEmission(in: arguments, start: start, end: end)
        let value = try await call("timen_update_time_entry", arguments: arguments)
        let candidate = value.firstValue(keys: ["time_entry", "entry", "data"]) ?? value
        let updated = try TimenMCPResponseParser.entry(from: candidate)
        try TimenMCPUpdateTiming.validateResponse(updated, requestedStart: start, requestedEnd: end)
        return updated
    }

    func updateEntryDuration(id: String, draft: TimerDraft, duration: TimeInterval) async throws -> TimeEntry {
        let arguments = try draftArguments(draft, tool: "timen_update_time_entry", additionalValues: [
            SemanticArgument(names: ["time_entry_id", "entry_id", "id"], value: Self.identifierValue(id)),
            TimenMCPUpdateTiming.durationArgument(duration),
        ])
        try TimenMCPUpdateTiming.validateDurationEmission(in: arguments)
        let value = try await call(
            "timen_update_time_entry",
            arguments: arguments
        )
        let candidate = value.firstValue(keys: ["time_entry", "entry", "data"]) ?? value
        let updated = try TimenMCPResponseParser.entry(from: candidate)
        try TimenMCPUpdateTiming.validateDurationResponse(updated, requestedDuration: duration)
        return updated
    }

    func deleteEntry(id: String) async throws {
        let result = try await performCall(
            "timen_delete_time_entry",
            arguments: arguments(for: "timen_delete_time_entry", values: [
                SemanticArgument(names: ["time_entry_id", "entry_id", "id"], value: Self.identifierValue(id)),
                SemanticArgument(names: ["confirm"], value: .bool(true)),
            ])
        )
        try TimenMCPToolResultParser.validateDeleteSuccess(result)
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
        let client = Client(name: "TimenBar", version: Self.clientVersion)
        try await client.connect(transport: transport)
        self.transport = transport
        self.client = client
    }

    private func call(_ name: String, arguments: [String: Value]? = nil) async throws -> Value {
        let result = try await performCall(name, arguments: arguments)
        return try TimenMCPToolResultParser.jsonValue(from: result, tool: name)
    }

    private func performCall(_ name: String, arguments: [String: Value]? = nil) async throws -> CallTool.Result {
        let traceID = String(UUID().uuidString.prefix(8))
#if DEBUG
        logger.debug("[\(traceID, privacy: .public)] → \(name, privacy: .public) args=\(Self.logJSON(arguments ?? [:]), privacy: .public)")
#endif
        let token = try await oauth.accessToken()
        tokenBox.update(token)
        let client = try await connectedClient()
        let result: CallTool.Result
        do {
            let context: RequestContext<CallTool.Result> = try await client.callTool(
                name: name,
                arguments: arguments
            )
            result = try await context.value
        } catch {
#if DEBUG
            logger.error("[\(traceID, privacy: .public)] ← \(name, privacy: .public) transport-error=\(error.localizedDescription, privacy: .public)")
#endif
            throw error
        }
#if DEBUG
        let text = TimenMCPToolResultParser.text(from: result)
        let responseDescription = result.structuredContent.map(Self.logJSONValue) ?? Self.truncated(text)
        if result.isError == true {
            logger.error("[\(traceID, privacy: .public)] ← \(name, privacy: .public) tool-error=\(responseDescription, privacy: .public)")
        } else {
            logger.debug("[\(traceID, privacy: .public)] ← \(name, privacy: .public) response=\(responseDescription, privacy: .public)")
        }
#endif
        return result
    }

    private func draftArguments(
        _ draft: TimerDraft,
        tool: String,
        additionalValues: [SemanticArgument] = []
    ) throws -> [String: Value] {
        try TimenMCPMutationContract.validateBillableSupport(for: tool, schema: schemas[tool])
        let output = arguments(for: tool, values: draftSemanticArguments(draft) + additionalValues)
        try TimenMCPMutationContract.validateBillableArgument(in: output, for: tool)
        return output
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
        TimenMCPArgumentBuilder.arguments(schema: schemas[tool], values: values)
    }

    private func emittedRecognizedArgument(
        for tool: String,
        arguments: [String: Value],
        names: Set<String>
    ) -> Bool {
        guard let properties = schemas[tool]?.objectValue?["properties"]?.objectValue else { return false }
        return names.contains { properties[$0] != nil && arguments[$0] != nil }
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

    private static var clientVersion: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String
        return [shortVersion, buildVersion]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "development"
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

struct SemanticArgument {
    var names: [String]
    var value: Value
}

enum TimenMCPUpdateTiming {
    private static let responseTolerance: TimeInterval = 1.01
    private static let durationAffectingNames: Set<String> = [
        "end", "ended_at", "end_time", "duration",
    ]

    static func arguments(start: Date?, end: Date?) -> [SemanticArgument] {
        var values: [SemanticArgument] = []
        if let start {
            values.append(
                SemanticArgument(
                    names: ["start", "started_at", "start_time"],
                    value: .string(TimenMCPGateway.dateString(start))
                )
            )
        }
        if let end {
            values.append(
                SemanticArgument(
                    names: ["end", "ended_at", "end_time"],
                    value: .string(TimenMCPGateway.dateString(end))
                )
            )
        }
        if let start, let end {
            values.append(durationArgument(end.timeIntervalSince(start)))
        }
        return values
    }

    static func durationArgument(_ duration: TimeInterval) -> SemanticArgument {
        SemanticArgument(
            names: ["duration"],
            value: .int(max(0, Int(duration.rounded())))
        )
    }

    static func validateEmission(in arguments: [String: Value], start: Date?, end: Date?) throws {
        guard start != nil, end != nil else { return }
        guard durationAffectingNames.contains(where: { arguments[$0] != nil }) else {
            throw TimenBarError.invalidResponse(
                "Tool timen_update_time_entry does not accept a recognized end or duration field; " +
                    "TimenBar cannot safely edit entry duration."
            )
        }
    }

    static func validateDurationEmission(in arguments: [String: Value]) throws {
        guard arguments["duration"] != nil else {
            throw TimenBarError.invalidResponse(
                "Tool timen_update_time_entry does not accept its documented duration field; " +
                    "TimenBar cannot safely extend this entry."
            )
        }
    }

    static func validateResponse(
        _ entry: TimeEntry,
        requestedStart: Date?,
        requestedEnd: Date?
    ) throws {
        if let requestedStart,
           abs(entry.start.timeIntervalSince(requestedStart)) > responseTolerance
        {
            throw TimenBarError.invalidResponse(
                "Timen did not apply the requested time-entry start. The entry was left open for review."
            )
        }

        if let requestedStart, let requestedEnd {
            let requestedDuration = max(0, requestedEnd.timeIntervalSince(requestedStart))
            try validateDurationResponse(entry, requestedDuration: requestedDuration)
        } else if let requestedEnd,
                  let actualEnd = entry.end,
                  abs(actualEnd.timeIntervalSince(requestedEnd)) > responseTolerance
        {
            throw TimenBarError.invalidResponse(
                "Timen did not apply the requested time-entry end. The entry was left open for review."
            )
        }
    }

    static func validateDurationResponse(_ entry: TimeEntry, requestedDuration: TimeInterval) throws {
        guard abs(entry.duration - max(0, requestedDuration)) <= responseTolerance else {
            throw TimenBarError.invalidResponse(
                "Timen did not apply the requested time-entry duration. The entry was left open for review."
            )
        }
    }
}

enum TimenMCPEntryScope {
    private static let teamWideRoles: Set<String> = ["admin", "owner"]

    static func normalizedRole(_ role: String?) -> String? {
        guard let normalized = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty
        else { return nil }
        return normalized
    }

    static func userFilterArguments(
        accountIdentifier: Value,
        normalizedRole: String?
    ) -> [SemanticArgument] {
        guard let normalizedRole, teamWideRoles.contains(normalizedRole) else { return [] }
        return [
            SemanticArgument(
                names: ["user_id", "member_id", "person_id", "owner_id"],
                value: accountIdentifier
            ),
            SemanticArgument(
                names: ["user_ids", "member_ids", "person_ids", "owner_ids"],
                value: .array([accountIdentifier])
            ),
        ]
    }

    static func unfilteredRequestIsCurrentUserScoped(normalizedRole: String?) -> Bool {
        normalizedRole == "member"
    }
}

enum TimenMCPArgumentBuilder {
    static func arguments(schema: Value?, values: [SemanticArgument]) -> [String: Value] {
        let propertyNames: Set<String>
        if let keys = schema?.objectValue?["properties"]?.objectValue?.keys {
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
}

enum TimenMCPMutationContract {
    static let draftToolNames = [
        "timen_start_timer",
        "timen_log_time",
        "timen_update_time_entry",
    ]
    static let billableArgumentNames = ["billable", "is_billable"]

    static func validateBillableSupport(in schemas: [String: Value]) throws {
        for tool in draftToolNames {
            try validateBillableSupport(for: tool, schema: schemas[tool])
        }
    }

    static func validateBillableSupport(for tool: String, schema: Value?) throws {
        guard let schema else { return }
        guard let schemaObject = schema.objectValue else {
            throw incompatibleBillableSchema(tool: tool)
        }
        guard let rawProperties = schemaObject["properties"] else {
            if schemaObject["additionalProperties"]?.boolValue == false {
                throw incompatibleBillableSchema(tool: tool)
            }
            // Some permissive/minimal schemas omit `properties`; in that case the
            // argument builder emits the canonical `billable` field and the server
            // remains responsible for validating it.
            return
        }
        guard let properties = rawProperties.objectValue else {
            throw incompatibleBillableSchema(tool: tool)
        }
        if properties.isEmpty, schemaObject["additionalProperties"]?.boolValue != false {
            return
        }
        guard let emittedName = billableArgumentNames.first(where: { properties[$0] != nil }),
              let fieldSchema = properties[emittedName],
              schemaAllowsBooleanTrue(fieldSchema)
        else {
            throw incompatibleBillableSchema(tool: tool)
        }
    }

    static func validateBillableArgument(in arguments: [String: Value], for tool: String) throws {
        let emittedTrue = billableArgumentNames.contains { arguments[$0]?.boolValue == true }
        guard emittedTrue else { throw incompatibleBillableSchema(tool: tool) }
    }

    private static func incompatibleBillableSchema(tool: String) -> TimenBarError {
        TimenBarError.invalidResponse(
            "Tool \(tool) does not accept a recognized billable field; TimenBar will not submit time that might be non-billable."
        )
    }

    private static func schemaAllowsBooleanTrue(_ schema: Value) -> Bool {
        if let booleanSchema = schema.boolValue { return booleanSchema }
        guard let object = schema.objectValue else { return false }
        if let type = object["type"] {
            let allowsBoolean = type.stringValue == "boolean"
                || type.arrayValue?.contains(.string("boolean")) == true
            guard allowsBoolean else { return false }
        }
        if let constant = object["const"], constant != .bool(true) { return false }
        if let allowedValues = object["enum"]?.arrayValue, !allowedValues.contains(.bool(true)) { return false }
        return true
    }
}

enum TimenMCPToolResultParser {
    static func text(from result: CallTool.Result) -> String {
        result.content.compactMap { content -> String? in
            if case let .text(text, _, _) = content { return text }
            return nil
        }.joined(separator: "\n")
    }

    static func jsonValue(from result: CallTool.Result, tool: String) throws -> Value {
        try validateToolSuccess(result)
        if let structuredContent = result.structuredContent { return structuredContent }
        let text = text(from: result)
        guard !text.isEmpty else { return .object([:]) }
        guard let value = decodeValue(text) else {
            throw TimenBarError.invalidResponse("Tool \(tool) returned text that was not valid JSON.")
        }
        return value
    }

    static func validateDeleteSuccess(_ result: CallTool.Result) throws {
        try validateToolSuccess(result)

        let response = result.structuredContent ?? decodeValue(text(from: result))
        if let response {
            if response.boolValue == false {
                throw TimenBarError.invalidResponse("Timen reported that the entry was not deleted.")
            }
            if let deleted = nestedBool(in: response, keys: ["deleted"], remainingDepth: 2), !deleted {
                throw TimenBarError.invalidResponse(message(in: response) ?? "Timen reported that the entry was not deleted.")
            }
            if let success = nestedBool(in: response, keys: ["success", "ok"], remainingDepth: 2), !success {
                throw TimenBarError.invalidResponse(message(in: response) ?? "Timen reported that deletion failed.")
            }
            if containsExplicitError(in: response, remainingDepth: 2) {
                throw TimenBarError.invalidResponse(message(in: response) ?? "Timen reported that deletion failed.")
            }
        }

        // Per MCP, `isError` absent/false means the tool call succeeded. Timen's
        // public tool reference does not prescribe a JSON deletion-result shape,
        // so successful plain-text and empty responses remain valid. Explicit
        // contradictory failure fields above still fail closed.
    }

    private static func validateToolSuccess(_ result: CallTool.Result) throws {
        guard result.isError != true else {
            let message = text(from: result).trimmingCharacters(in: .whitespacesAndNewlines)
            throw TimenBarError.invalidResponse(message.isEmpty ? "Timen reported that the tool call failed." : message)
        }
    }

    private static func decodeValue(_ text: String) -> Value? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private static func nestedBool(in value: Value, keys: [String], remainingDepth: Int) -> Bool? {
        if let direct = value.bool(keys: keys) { return direct }
        guard remainingDepth > 0, let object = value.objectValue else { return nil }
        for wrapper in ["data", "result", "response"] {
            if let nested = object[wrapper],
               let result = nestedBool(in: nested, keys: keys, remainingDepth: remainingDepth - 1)
            {
                return result
            }
        }
        return nil
    }

    private static func containsExplicitError(in value: Value, remainingDepth: Int) -> Bool {
        guard let object = value.objectValue else { return false }
        if let error = object["error"], isMeaningfulError(error) { return true }
        if let errors = object["errors"], isMeaningfulError(errors) { return true }
        if let status = object["status"]?.stringValue?.lowercased(),
           ["error", "failed", "failure"].contains(status)
        {
            return true
        }
        guard remainingDepth > 0 else { return false }
        for wrapper in ["data", "result", "response"] {
            if let nested = object[wrapper], containsExplicitError(in: nested, remainingDepth: remainingDepth - 1) {
                return true
            }
        }
        return false
    }

    private static func isMeaningfulError(_ value: Value) -> Bool {
        if value == .null || value.boolValue == false { return false }
        if let text = value.stringValue {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let values = value.arrayValue { return !values.isEmpty }
        if let values = value.objectValue { return !values.isEmpty }
        return true
    }

    private static func message(in value: Value) -> String? {
        if let message = value.string(keys: ["message", "error"]) { return message }
        guard let object = value.objectValue else { return nil }
        for wrapper in ["data", "result", "response"] {
            if let nested = object[wrapper], let message = message(in: nested) { return message }
        }
        return nil
    }
}

enum TimenMCPResponseParser {
    static let userFilterArgumentNames: Set<String> = [
        "user_id", "member_id", "person_id", "owner_id",
        "user_ids", "member_ids", "person_ids", "owner_ids",
    ]

    private static let directOwnerIDKeys = [
        "user_id", "member_id", "person_id", "owner_id", "employee_id",
    ]
    private static let nestedOwnerKeys = ["user", "member", "person", "owner", "employee"]
    private static let nestedOwnerIDKeys = [
        "id", "user_id", "member_id", "person_id", "owner_id", "employee_id",
    ]

    static func account(from response: Value) throws -> TimenAccount {
        let root = response.firstObject(keys: ["data"]) ?? response
        let object = root.firstObject(keys: ["user", "me", "account"]) ?? root
        guard object.objectValue != nil else {
            throw TimenBarError.invalidResponse("Current-account response was not an object.")
        }
        guard let id = identifier(in: object, keys: ["id", "user_id"]), id.lowercased() != "me" else {
            throw TimenBarError.invalidResponse("Current-account response did not include a stable account ID.")
        }
        return TimenAccount(
            id: id,
            name: nonEmptyString(in: object, keys: ["name", "full_name"]) ?? "Timen user",
            email: nonEmptyString(in: object, keys: ["email"]),
            teamName: nonEmptyString(in: object, keys: ["team_name", "team", "workspace_name"]) ?? "Timen",
            role: nonEmptyString(in: object, keys: ["role"]),
            timeZoneIdentifier: nonEmptyString(in: object, keys: ["time_zone", "timezone", "timeZone"])
                ?? TimeZone.current.identifier
        )
    }

    static func runningTimer(from response: Value) throws -> RunningTimer? {
        let candidate = response.firstValue(keys: ["timer", "running_timer", "runningTimer", "data"]) ?? response
        if candidate == .null || candidate.objectValue?.isEmpty == true { return nil }
        guard candidate.objectValue != nil else {
            throw TimenBarError.invalidResponse("Running-timer response was not an object.")
        }
        guard let id = identifier(in: candidate, keys: ["id", "timer_id"]) else {
            throw TimenBarError.invalidResponse("Running timer did not include a stable timer ID.")
        }
        guard let startedAt = candidate.date(keys: ["started_at", "start", "start_time", "startedAt"]) else {
            throw TimenBarError.invalidResponse("Running timer did not include a valid start time.")
        }
        let project = candidate.firstObject(keys: ["project"])
        let projectID = identifier(in: candidate, keys: ["project_id", "projectId"])
            ?? project.flatMap { identifier(in: $0, keys: ["id", "project_id"]) }
        if project != nil, projectID == nil {
            throw TimenBarError.invalidResponse("Running timer included a project without a stable project ID.")
        }
        return RunningTimer(
            id: id,
            remoteID: id,
            startedAt: startedAt,
            projectID: projectID,
            projectName: nonEmptyString(in: candidate, keys: ["project_name"])
                ?? project.flatMap { nonEmptyString(in: $0, keys: ["name", "project_name"]) },
            clientName: nonEmptyString(in: candidate, keys: ["client_name"])
                ?? project.flatMap { nonEmptyString(in: $0, keys: ["client_name"]) },
            note: candidate.string(keys: ["note", "description"]) ?? "",
            tags: embeddedTags(from: candidate.firstValue(keys: ["tags"])),
            billable: candidate.bool(keys: ["billable", "is_billable"]) ?? false,
            syncState: .synced
        )
    }

    static func projects(from response: Value) throws -> [TimenProject] {
        let items = try requiredArray(in: response, keys: ["projects", "data"], description: "projects")
        var seenIDs = Set<String>()
        return try items.enumerated().map { index, item in
            guard item.objectValue != nil else {
                throw TimenBarError.invalidResponse("Project at index \(index) was not an object.")
            }
            guard let id = identifier(in: item, keys: ["id", "project_id"]) else {
                throw TimenBarError.invalidResponse("Project at index \(index) did not include a stable project ID.")
            }
            guard seenIDs.insert(id).inserted else {
                throw TimenBarError.invalidResponse("Projects response included duplicate project ID \(id).")
            }
            guard let name = nonEmptyString(in: item, keys: ["name", "project_name"]) else {
                throw TimenBarError.invalidResponse("Project \(id) did not include a name.")
            }
            let client = item.firstObject(keys: ["client"])
            return TimenProject(
                id: id,
                name: name,
                clientName: nonEmptyString(in: item, keys: ["client_name"])
                    ?? client.flatMap { nonEmptyString(in: $0, keys: ["name"]) },
                isActive: !(item.bool(keys: ["archived", "is_archived"]) ?? false)
            )
        }
    }

    static func entries(
        from response: Value,
        currentAccountID: String,
        requestWasCurrentUserScoped: Bool
    ) throws -> [TimeEntry] {
        guard !currentAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TimenBarError.invalidResponse("Cannot verify time-entry ownership without an account ID.")
        }
        let items = try requiredArray(
            in: response,
            keys: ["time_entries", "entries", "data"],
            description: "time entries"
        )
        var seenIDs = Set<String>()
        return try items.enumerated().map { index, item in
            do {
                try validateOwnership(
                    of: item,
                    currentAccountID: currentAccountID,
                    requestWasCurrentUserScoped: requestWasCurrentUserScoped
                )
                let parsed = try entry(from: item)
                guard seenIDs.insert(parsed.id).inserted else {
                    throw TimenBarError.invalidResponse("Response included duplicate time-entry ID \(parsed.id).")
                }
                return parsed
            } catch TimenBarError.invalidResponse(let message) {
                throw TimenBarError.invalidResponse("Time entry at index \(index): \(message)")
            }
        }
    }

    static func entry(from value: Value) throws -> TimeEntry {
        guard value.objectValue != nil else {
            throw TimenBarError.invalidResponse("Time entry was not an object.")
        }
        guard let remoteID = identifier(in: value, keys: ["id", "time_entry_id", "entry_id"]) else {
            throw TimenBarError.invalidResponse("Time entry did not include a stable entry ID.")
        }
        guard let start = value.date(keys: ["start", "started_at", "start_time", "startedAt", "date", "entry_date"]) else {
            throw TimenBarError.invalidResponse("Time entry \(remoteID) did not include a valid start time.")
        }
        let explicitEnd = value.date(keys: ["end", "ended_at", "end_time", "endedAt"])
        let parsedDuration = TimenDurationParser.duration(from: value)
        let end = explicitEnd ?? parsedDuration.map { start.addingTimeInterval($0) } ?? start
        guard end >= start else {
            throw TimenBarError.invalidResponse("Time entry \(remoteID) ended before it started.")
        }
        let project = value.firstObject(keys: ["project"])
        let projectID = identifier(in: value, keys: ["project_id", "projectId"])
            ?? project.flatMap { identifier(in: $0, keys: ["id", "project_id"]) }
        if project != nil, projectID == nil {
            throw TimenBarError.invalidResponse("Time entry \(remoteID) included a project without a stable project ID.")
        }
        return TimeEntry(
            id: remoteID,
            remoteID: remoteID,
            start: start,
            end: end,
            projectID: projectID,
            projectName: nonEmptyString(in: value, keys: ["project_name"])
                ?? project.flatMap { nonEmptyString(in: $0, keys: ["name", "project_name"]) },
            clientName: nonEmptyString(in: value, keys: ["client_name"])
                ?? project.flatMap { nonEmptyString(in: $0, keys: ["client_name"]) },
            note: value.string(keys: ["note", "description"]) ?? "",
            tags: embeddedTags(from: value.firstValue(keys: ["tags"])),
            billable: value.bool(keys: ["billable", "is_billable"]) ?? false,
            syncState: .synced
        )
    }

    static func tagList(from response: Value) throws -> [TimenTag] {
        let items = try requiredArray(in: response, keys: ["tags", "data"], description: "tags")
        var seenIDs = Set<String>()
        return try items.enumerated().map { index, item in
            guard item.objectValue != nil else {
                throw TimenBarError.invalidResponse("Tag at index \(index) was not an object.")
            }
            guard let id = identifier(in: item, keys: ["id", "tag_id"]) else {
                throw TimenBarError.invalidResponse("Tag at index \(index) did not include a stable tag ID.")
            }
            guard seenIDs.insert(id).inserted else {
                throw TimenBarError.invalidResponse("Tags response included duplicate tag ID \(id).")
            }
            guard let name = nonEmptyString(in: item, keys: ["name", "tag_name"]) else {
                throw TimenBarError.invalidResponse("Tag \(id) did not include a name.")
            }
            return TimenTag(id: id, name: name)
        }
    }

    static func embeddedTags(from value: Value?) -> [TimenTag] {
        guard let value else { return [] }
        return value.array(keys: ["tags", "data"]).compactMap { item in
            if let name = nonEmptyScalarString(item) { return TimenTag(id: name, name: name) }
            guard let name = nonEmptyString(in: item, keys: ["name", "tag_name"]) else { return nil }
            return TimenTag(id: identifier(in: item, keys: ["id", "tag_id"]) ?? name, name: name)
        }
    }

    static func identifier(in value: Value, keys: [String]) -> String? {
        guard let scalar = value.firstValue(keys: keys) else { return nil }
        return nonEmptyScalarString(scalar)
    }

    private static func validateOwnership(
        of value: Value,
        currentAccountID: String,
        requestWasCurrentUserScoped: Bool
    ) throws {
        guard let object = value.objectValue else {
            throw TimenBarError.invalidResponse("Time entry was not an object.")
        }
        var ownerIDs = Set<String>()

        for key in directOwnerIDKeys {
            if let raw = object[key], let id = nonEmptyScalarString(raw) { ownerIDs.insert(id) }
        }
        for key in nestedOwnerKeys {
            guard let rawOwner = object[key] else { continue }
            if let ownerObject = rawOwner.objectValue {
                for idKey in nestedOwnerIDKeys {
                    if let rawID = ownerObject[idKey], let id = nonEmptyScalarString(rawID) { ownerIDs.insert(id) }
                }
            } else if let id = nonEmptyScalarString(rawOwner) {
                ownerIDs.insert(id)
            }
        }

        if ownerIDs.isEmpty {
            guard requestWasCurrentUserScoped else {
                throw TimenBarError.invalidResponse(
                    "Time entry omitted owner metadata and the request was not known to be scoped to the current account."
                )
            }
            return
        }
        guard ownerIDs.count == 1, ownerIDs.first == currentAccountID else {
            throw TimenBarError.invalidResponse(
                "Time entry owner did not unambiguously match the current account."
            )
        }
    }

    private static func requiredArray(
        in value: Value,
        keys: [String],
        description: String
    ) throws -> [Value] {
        if let array = nestedArray(in: value, keys: keys, remainingDepth: 2) { return array }
        throw TimenBarError.invalidResponse("Response did not include a \(description) array.")
    }

    private static func nestedArray(in value: Value, keys: [String], remainingDepth: Int) -> [Value]? {
        if let array = value.arrayValue { return array }
        guard remainingDepth > 0, let object = value.objectValue else { return nil }
        for key in keys {
            if let nested = object[key],
               let array = nestedArray(in: nested, keys: keys, remainingDepth: remainingDepth - 1)
            {
                return array
            }
        }
        return nil
    }

    private static func nonEmptyString(in value: Value, keys: [String]) -> String? {
        guard let raw = value.string(keys: keys)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return raw
    }

    private static func nonEmptyScalarString(_ value: Value) -> String? {
        let raw: String?
        if let string = value.stringValue {
            raw = string
        } else if let int = value.intValue {
            raw = String(int)
        } else {
            raw = nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
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
