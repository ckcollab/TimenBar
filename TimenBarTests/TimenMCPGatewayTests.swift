import Foundation
import MCP
import XCTest
@testable import TimenBar

final class TimenMCPGatewayTests: XCTestCase {
    func testTopLevelTagsRequireStableUniqueIDs() throws {
        let response = try fixture(
            #"{"data":{"tags":[{"id":10,"name":"Design"},{"tag_id":"20","tag_name":"Review"}]}}"#
        )

        let tags = try TimenMCPResponseParser.tagList(from: response)

        XCTAssertEqual(tags, [
            TimenTag(id: "10", name: "Design"),
            TimenTag(id: "20", name: "Review"),
        ])
    }

    func testTopLevelTagWithoutStableIDFailsEntireList() throws {
        let response = try fixture(#"{"tags":[{"id":"1","name":"Design"},{"name":"Review"}]}"#)

        assertInvalidResponse(contains: "index 1") {
            try TimenMCPResponseParser.tagList(from: response)
        }
    }

    func testMalformedTopLevelTagFailsEntireList() throws {
        let response = try fixture(#"{"tags":[{"id":"1","name":"Design"},"Review"]}"#)

        assertInvalidResponse(contains: "not an object") {
            try TimenMCPResponseParser.tagList(from: response)
        }
    }

    func testDuplicateTopLevelTagIDFailsEntireList() throws {
        let response = try fixture(
            #"{"tags":[{"id":"1","name":"Design"},{"id":1,"name":"Review"}]}"#
        )

        assertInvalidResponse(contains: "duplicate tag ID 1") {
            try TimenMCPResponseParser.tagList(from: response)
        }
    }

    func testEmbeddedEntryTagsRetainFlexibleLegacyShapes() throws {
        let response = try fixture(
            #"["Design",{"name":"Review"},{"id":3,"name":"Build"},{"id":4},false]"#
        )

        XCTAssertEqual(TimenMCPResponseParser.embeddedTags(from: response), [
            TimenTag(id: "Design", name: "Design"),
            TimenTag(id: "Review", name: "Review"),
            TimenTag(id: "3", name: "Build"),
        ])
    }

    func testSchemaAwareArgumentsEmitRecognizedBillableTrue() throws {
        let schema = inputSchema(properties: ["description", "is_billable", "tag_ids"])
        try TimenMCPMutationContract.validateBillableSupport(for: "timen_start_timer", schema: schema)

        let arguments = TimenMCPArgumentBuilder.arguments(schema: schema, values: [
            SemanticArgument(names: ["note", "description"], value: .string("Work")),
            SemanticArgument(names: ["billable", "is_billable"], value: .bool(true)),
        ])

        XCTAssertEqual(arguments["description"], .string("Work"))
        XCTAssertEqual(arguments["is_billable"], .bool(true))
        XCTAssertNil(arguments["billable"])
        XCTAssertNoThrow(
            try TimenMCPMutationContract.validateBillableArgument(in: arguments, for: "timen_start_timer")
        )
    }

    func testDeleteArgumentsEmitRequiredIDEvenWhenSchemaAdvertisesTimeEntryID() {
        let schema = inputSchema(properties: ["time_entry_id", "confirm"], required: ["id"])
        let arguments = TimenMCPArgumentBuilder.arguments(schema: schema, values: [
            SemanticArgument(names: ["id", "time_entry_id", "entry_id"], value: .int(42)),
            SemanticArgument(names: ["confirm"], value: .bool(true)),
        ])

        XCTAssertEqual(arguments["id"], .int(42))
        XCTAssertEqual(arguments["time_entry_id"], .int(42))
        XCTAssertEqual(arguments["confirm"], .bool(true))
    }

    func testDeleteArgumentsEmitIDWhenSchemaOmitsPropertyNames() {
        let arguments = TimenMCPArgumentBuilder.arguments(schema: nil, values: [
            SemanticArgument(names: ["id", "time_entry_id", "entry_id"], value: .string("100")),
        ])

        XCTAssertEqual(arguments["id"], .string("100"))
        XCTAssertNil(arguments["time_entry_id"])
    }

    func testCompletedEntryUpdateEmitsDurationAlongsideStartAndEnd() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T16:00:00Z"))
        let end = start.addingTimeInterval(5_400)
        let arguments = TimenMCPArgumentBuilder.arguments(
            schema: inputSchema(properties: ["start", "end", "duration"]),
            values: TimenMCPUpdateTiming.arguments(start: start, end: end)
        )

        XCTAssertNotNil(arguments["start"]?.stringValue)
        XCTAssertNotNil(arguments["end"]?.stringValue)
        XCTAssertEqual(arguments["duration"], .int(5_400))
    }

    func testCompletedEntryUpdateSupportsTimenStoppedAtSchema() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T16:00:00Z"))
        let end = start.addingTimeInterval(5_400)
        let arguments = TimenMCPArgumentBuilder.arguments(
            schema: inputSchema(properties: ["started_at", "stopped_at", "duration"]),
            values: TimenMCPUpdateTiming.arguments(start: start, end: end)
        )

        XCTAssertNotNil(arguments["started_at"]?.stringValue)
        XCTAssertNotNil(arguments["stopped_at"]?.stringValue)
        XCTAssertEqual(arguments["duration"], .int(5_400))
        XCTAssertNoThrow(try TimenMCPUpdateTiming.validateEmission(
            in: arguments,
            start: start,
            end: end
        ))
    }

    func testCompletedEntryUpdateSupportsDurationSecondsFallback() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T16:00:00Z"))
        let end = start.addingTimeInterval(7_200)
        let arguments = TimenMCPArgumentBuilder.arguments(
            schema: inputSchema(properties: ["started_at", "duration_seconds"]),
            values: TimenMCPUpdateTiming.arguments(start: start, end: end)
        )

        XCTAssertNotNil(arguments["started_at"]?.stringValue)
        XCTAssertEqual(arguments["duration_seconds"], .int(7_200))
        XCTAssertNoThrow(try TimenMCPUpdateTiming.validateEmission(
            in: arguments,
            start: start,
            end: end
        ))
        XCTAssertNoThrow(try TimenMCPUpdateTiming.validateDurationEmission(in: arguments))
    }

    func testCompletedEntryUpdateOmitsDurationForPartialTimingChange() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T16:00:00Z"))
        let arguments = TimenMCPArgumentBuilder.arguments(
            schema: inputSchema(properties: ["start", "duration"]),
            values: TimenMCPUpdateTiming.arguments(start: start, end: nil)
        )

        XCTAssertNotNil(arguments["start"]?.stringValue)
        XCTAssertNil(arguments["duration"])
    }

    func testCompletedEntryUpdateSupportsDurationOnlySchema() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T16:00:00Z"))
        let end = start.addingTimeInterval(7_200)
        let arguments = TimenMCPArgumentBuilder.arguments(
            schema: inputSchema(properties: ["duration"]),
            values: TimenMCPUpdateTiming.arguments(start: start, end: end)
        )

        XCTAssertEqual(arguments, ["duration": .int(7_200)])
        XCTAssertNoThrow(try TimenMCPUpdateTiming.validateEmission(in: arguments, start: start, end: end))
        XCTAssertNoThrow(try TimenMCPUpdateTiming.validateDurationEmission(in: arguments))
    }

    func testCompletedEntryUpdateSupportsEndOnlySchema() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T16:00:00Z"))
        let end = start.addingTimeInterval(7_200)
        let arguments = TimenMCPArgumentBuilder.arguments(
            schema: inputSchema(properties: ["end"]),
            values: TimenMCPUpdateTiming.arguments(start: start, end: end)
        )

        XCTAssertNotNil(arguments["end"]?.stringValue)
        XCTAssertNoThrow(try TimenMCPUpdateTiming.validateEmission(in: arguments, start: start, end: end))
    }

    func testCompletedEntryUpdateRejectsSchemaThatCannotChangeDuration() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T16:00:00Z"))
        let end = start.addingTimeInterval(7_200)
        let arguments = TimenMCPArgumentBuilder.arguments(
            schema: inputSchema(properties: ["start"]),
            values: TimenMCPUpdateTiming.arguments(start: start, end: end)
        )

        assertInvalidResponse(contains: "cannot safely edit entry duration") {
            try TimenMCPUpdateTiming.validateEmission(in: arguments, start: start, end: end)
        }
    }

    func testCompletedEntryUpdateAcceptsServerTimingRoundedToSeconds() throws {
        let requestedStart = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T16:00:00Z"))
            .addingTimeInterval(0.75)
        let requestedEnd = requestedStart.addingTimeInterval(5_400)
        let returned = completedEntry(
            start: requestedStart.addingTimeInterval(-0.75),
            duration: 5_400
        )

        XCTAssertNoThrow(try TimenMCPUpdateTiming.validateResponse(
            returned,
            requestedStart: requestedStart,
            requestedEnd: requestedEnd
        ))
    }

    func testCompletedEntryUpdateRejectsStaleServerDuration() throws {
        let requestedStart = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T16:00:00Z"))
        let requestedEnd = requestedStart.addingTimeInterval(5_400)
        let stale = completedEntry(start: requestedStart, duration: 3_600)

        assertInvalidResponse(contains: "did not apply the requested time-entry duration") {
            try TimenMCPUpdateTiming.validateResponse(
                stale,
                requestedStart: requestedStart,
                requestedEnd: requestedEnd
            )
        }
    }

    func testCompletedEntryUpdateRejectsStaleServerStart() throws {
        let requestedStart = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T16:00:00Z"))
        let requestedEnd = requestedStart.addingTimeInterval(5_400)
        let stale = completedEntry(start: requestedStart.addingTimeInterval(-60), duration: 5_400)

        assertInvalidResponse(contains: "did not apply the requested time-entry start") {
            try TimenMCPUpdateTiming.validateResponse(
                stale,
                requestedStart: requestedStart,
                requestedEnd: requestedEnd
            )
        }
    }

    func testDurationOnlyUpdateRejectsSchemaThatDropsDuration() {
        let arguments = TimenMCPArgumentBuilder.arguments(
            schema: inputSchema(properties: ["end"]),
            values: [TimenMCPUpdateTiming.durationArgument(5_400)]
        )

        assertInvalidResponse(contains: "does not accept its documented duration field") {
            try TimenMCPUpdateTiming.validateDurationEmission(in: arguments)
        }
    }

    func testDurationOnlyUpdateRejectsStaleServerDuration() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T16:00:00Z"))
        let stale = completedEntry(start: start, duration: 3_600)

        assertInvalidResponse(contains: "did not apply the requested time-entry duration") {
            try TimenMCPUpdateTiming.validateDurationResponse(stale, requestedDuration: 5_400)
        }
    }

    func testEntryResponseParsesStoppedAt() throws {
        let value = try fixture(
            #"{"id":"100","started_at":"2026-08-20T16:00:00Z","stopped_at":"2026-08-20T17:30:00Z"}"#
        )

        let entry = try TimenMCPResponseParser.entry(from: value)

        XCTAssertEqual(entry.duration, 5_400, accuracy: 0.01)
    }

    func testOwnerAndAdminEntryQueriesEmitRecognizedSelfFilter() {
        let schema = inputSchema(properties: ["member_id"])

        for rawRole in ["owner", " ADMIN "] {
            let role = TimenMCPEntryScope.normalizedRole(rawRole)
            let arguments = TimenMCPArgumentBuilder.arguments(
                schema: schema,
                values: TimenMCPEntryScope.userFilterArguments(
                    accountIdentifier: .int(42),
                    normalizedRole: role
                )
            )

            XCTAssertEqual(arguments["member_id"], .int(42), "role=\(rawRole)")
            XCTAssertFalse(
                TimenMCPEntryScope.unfilteredRequestIsCurrentUserScoped(normalizedRole: role),
                "role=\(rawRole)"
            )
        }
    }

    func testMemberEntryQueryOmitsTeamMemberFilterAndUsesServerScope() {
        let role = TimenMCPEntryScope.normalizedRole(" MEMBER ")
        let arguments = TimenMCPArgumentBuilder.arguments(
            schema: inputSchema(properties: ["member_id"]),
            values: TimenMCPEntryScope.userFilterArguments(
                accountIdentifier: .int(42),
                normalizedRole: role
            )
        )

        XCTAssertEqual(role, "member")
        XCTAssertTrue(arguments.isEmpty)
        XCTAssertTrue(TimenMCPEntryScope.unfilteredRequestIsCurrentUserScoped(normalizedRole: role))
    }

    func testUnknownEntryRolesOmitFilterAndDoNotEstablishServerScope() {
        for role in [TimenMCPEntryScope.normalizedRole(nil), TimenMCPEntryScope.normalizedRole("manager")] {
            let arguments = TimenMCPArgumentBuilder.arguments(
                schema: inputSchema(properties: ["member_id"]),
                values: TimenMCPEntryScope.userFilterArguments(
                    accountIdentifier: .int(42),
                    normalizedRole: role
                )
            )

            XCTAssertTrue(arguments.isEmpty)
            XCTAssertFalse(TimenMCPEntryScope.unfilteredRequestIsCurrentUserScoped(normalizedRole: role))
        }
    }

    func testCapabilityValidationRejectsDraftToolWithoutBillableField() {
        let schema = inputSchema(properties: ["description", "project_id"])

        assertInvalidResponse(contains: "timen_log_time") {
            try TimenMCPMutationContract.validateBillableSupport(for: "timen_log_time", schema: schema)
        }
    }

    func testCapabilityValidationRejectsBillableFieldThatCannotAcceptTrue() throws {
        let schema = try fixture(
            #"{"type":"object","properties":{"billable":{"type":"string"}},"additionalProperties":false}"#
        )

        assertInvalidResponse(contains: "billable field") {
            try TimenMCPMutationContract.validateBillableSupport(for: "timen_start_timer", schema: schema)
        }
    }

    func testClosedSchemaWithoutPropertiesRejectsBillableMutation() throws {
        let schema = try fixture(#"{"type":"object","additionalProperties":false}"#)

        assertInvalidResponse(contains: "billable field") {
            try TimenMCPMutationContract.validateBillableSupport(for: "timen_start_timer", schema: schema)
        }
    }

    func testCapabilityValidationChecksEveryDraftMutationTool() {
        XCTAssertEqual(
            Set(TimenMCPMutationContract.draftToolNames),
            Set(["timen_start_timer", "timen_log_time", "timen_update_time_entry"])
        )

        var schemas = Dictionary(
            uniqueKeysWithValues: TimenMCPMutationContract.draftToolNames.map {
                ($0, inputSchema(properties: ["billable"]))
            }
        )
        schemas["timen_update_time_entry"] = inputSchema(properties: ["entry_id"])

        assertInvalidResponse(contains: "timen_update_time_entry") {
            try TimenMCPMutationContract.validateBillableSupport(in: schemas)
        }
    }

    func testPermissiveSchemaStillEmitsCanonicalBillableField() throws {
        let schema = try fixture(#"{"type":"object"}"#)
        try TimenMCPMutationContract.validateBillableSupport(for: "timen_start_timer", schema: schema)

        let arguments = TimenMCPArgumentBuilder.arguments(schema: schema, values: [
            SemanticArgument(names: ["billable", "is_billable"], value: .bool(true)),
        ])

        XCTAssertEqual(arguments["billable"], .bool(true))
        XCTAssertNoThrow(
            try TimenMCPMutationContract.validateBillableArgument(in: arguments, for: "timen_start_timer")
        )
    }

    func testMissingOrFalseBillableArgumentIsRejectedBeforeMutation() {
        assertInvalidResponse(contains: "billable field") {
            try TimenMCPMutationContract.validateBillableArgument(in: [:], for: "timen_update_time_entry")
        }
        assertInvalidResponse(contains: "billable field") {
            try TimenMCPMutationContract.validateBillableArgument(
                in: ["billable": .bool(false)],
                for: "timen_update_time_entry"
            )
        }
    }

    func testDeleteAcceptsSuccessfulUnstructuredMCPResult() {
        let result = CallTool.Result(
            content: [.text(text: "Time entry deleted.", annotations: nil, _meta: nil)]
        )

        XCTAssertNoThrow(try TimenMCPToolResultParser.validateDeleteSuccess(result))
    }

    func testDeleteRejectsExplicitFalseEvenWhenMCPResultIsNotMarkedAsError() {
        let result = CallTool.Result(
            structuredContent: Optional<Value>.some(.object([
                "data": .object(["deleted": .bool(false)]),
                "message": .string("Entry is locked."),
            ])),
            isError: false
        )

        assertInvalidResponse(contains: "locked") {
            try TimenMCPToolResultParser.validateDeleteSuccess(result)
        }
    }

    func testDeleteRejectsMCPToolError() {
        let result = CallTool.Result(
            content: [.text(text: "Entry is locked.", annotations: nil, _meta: nil)],
            isError: true
        )

        assertInvalidResponse(contains: "locked") {
            try TimenMCPToolResultParser.validateDeleteSuccess(result)
        }
    }

    func testDeleteDoesNotMistakeExplicitFalseErrorFieldForFailure() {
        let result = CallTool.Result(
            structuredContent: Optional<Value>.some(.object([
                "deleted": .bool(true),
                "error": .bool(false),
                "errors": .array([]),
            ])),
            isError: false
        )

        XCTAssertNoThrow(try TimenMCPToolResultParser.validateDeleteSuccess(result))
    }

    func testDataBearingCallStillRejectsNonJSONSuccessText() {
        let result = CallTool.Result(
            content: [.text(text: "Done", annotations: nil, _meta: nil)],
            isError: false
        )

        assertInvalidResponse(contains: "not valid JSON") {
            try TimenMCPToolResultParser.jsonValue(from: result, tool: "timen_list_tags")
        }
    }

    func testAccountRequiresStableID() throws {
        let response = try fixture(#"{"data":{"user":{"name":"Eric"}}}"#)

        assertInvalidResponse(contains: "account ID") {
            try TimenMCPResponseParser.account(from: response)
        }
    }

    func testAccountParsesTimenTheme() throws {
        let response = try fixture(
            #"{"id":253,"name":"Eric","team_name":"CKC","timezone":"America/Los_Angeles","theme":"purple"}"#
        )

        let account = try TimenMCPResponseParser.account(from: response)

        XCTAssertEqual(account.theme, .purple)
        XCTAssertEqual(account.effectiveTheme, .purple)
    }

    func testAccountParsesDefaultAsDistinctTheme() throws {
        let response = try fixture(
            #"{"id":253,"name":"Eric","team_name":"CKC","timezone":"UTC","theme":"default"}"#
        )

        let account = try TimenMCPResponseParser.account(from: response)

        XCTAssertEqual(account.theme, .standard)
        XCTAssertEqual(account.effectiveTheme, .standard)
        XCTAssertEqual(account.effectiveTheme.displayName, "Default")
    }

    func testMissingOrUnknownAccountThemeDefaultsToBlue() throws {
        let missing = try TimenMCPResponseParser.account(from: fixture(
            #"{"id":253,"name":"Eric","team_name":"CKC","timezone":"UTC"}"#
        ))
        let unknown = try TimenMCPResponseParser.account(from: fixture(
            #"{"id":253,"name":"Eric","team_name":"CKC","timezone":"UTC","theme":"midnight"}"#
        ))

        XCTAssertNil(missing.theme)
        XCTAssertNil(unknown.theme)
        XCTAssertEqual(missing.effectiveTheme, .standard)
        XCTAssertEqual(unknown.effectiveTheme, .standard)
    }

    func testLegacyCachedAccountWithoutThemeStillDecodes() throws {
        let data = try XCTUnwrap(
            #"{"id":"253","name":"Eric","email":null,"teamName":"CKC","role":"owner","timeZoneIdentifier":"UTC"}"#
                .data(using: .utf8)
        )

        let account = try JSONDecoder().decode(TimenAccount.self, from: data)

        XCTAssertNil(account.theme)
        XCTAssertEqual(account.effectiveTheme, .standard)
    }

    func testProjectsRequireStableIDs() throws {
        let response = try fixture(#"{"projects":[{"name":"Internal"}]}"#)

        assertInvalidResponse(contains: "project ID") {
            try TimenMCPResponseParser.projects(from: response)
        }
    }

    func testEntriesRequireStableIDs() throws {
        let response = try fixture(
            #"{"entries":[{"start":"2026-08-20T16:00:00Z","end":"2026-08-20T17:00:00Z"}]}"#
        )

        assertInvalidResponse(contains: "entry ID") {
            try TimenMCPResponseParser.entries(
                from: response,
                currentAccountID: "42",
                requestWasCurrentUserScoped: true
            )
        }
    }

    func testMalformedRowFailsEntireRefresh() throws {
        let response = try fixture(
            """
            {
              "entries": [
                {
                  "id": "100",
                  "user_id": "42",
                  "start": "2026-08-20T16:00:00Z",
                  "end": "2026-08-20T17:00:00Z"
                },
                {
                  "id": "101",
                  "user_id": "42",
                  "end": "2026-08-20T18:00:00Z"
                }
              ]
            }
            """
        )

        assertInvalidResponse(contains: "index 1") {
            try TimenMCPResponseParser.entries(
                from: response,
                currentAccountID: "42",
                requestWasCurrentUserScoped: false
            )
        }
    }

    func testExplicitOtherUserEntryIsRejectedEvenWithServerFilter() throws {
        let response = try fixture(
            #"{"entries":[{"id":"100","user_id":"99","start":"2026-08-20T16:00:00Z","end":"2026-08-20T17:00:00Z"}]}"#
        )

        assertInvalidResponse(contains: "current account") {
            try TimenMCPResponseParser.entries(
                from: response,
                currentAccountID: "42",
                requestWasCurrentUserScoped: true
            )
        }
    }

    func testOwnerlessEntryIsRejectedWhenRequestScopeIsUnknown() throws {
        let response = try ownerlessEntryResponse()

        assertInvalidResponse(contains: "not known to be scoped") {
            try TimenMCPResponseParser.entries(
                from: response,
                currentAccountID: "42",
                requestWasCurrentUserScoped: false
            )
        }
    }

    func testOwnerlessEntryIsAcceptedForUnfilteredMemberRequest() throws {
        let response = try ownerlessEntryResponse()
        let memberScope = TimenMCPEntryScope.unfilteredRequestIsCurrentUserScoped(
            normalizedRole: TimenMCPEntryScope.normalizedRole("member")
        )

        let entries = try TimenMCPResponseParser.entries(
            from: response,
            currentAccountID: "42",
            requestWasCurrentUserScoped: memberScope
        )

        XCTAssertEqual(entries.map(\.id), ["100"])
    }

    func testMatchingOwnerIsAcceptedWithoutServerFilter() throws {
        let response = try fixture(
            #"{"entries":[{"id":"100","owner":{"id":42},"start":"2026-08-20T16:00:00Z","end":"2026-08-20T17:00:00Z"}]}"#
        )

        let entries = try TimenMCPResponseParser.entries(
            from: response,
            currentAccountID: "42",
            requestWasCurrentUserScoped: false
        )

        XCTAssertEqual(entries.map(\.id), ["100"])
    }

    private func ownerlessEntryResponse() throws -> Value {
        try fixture(
            #"{"entries":[{"id":"100","start":"2026-08-20T16:00:00Z","end":"2026-08-20T17:00:00Z"}]}"#
        )
    }

    private func completedEntry(start: Date, duration: TimeInterval) -> TimeEntry {
        TimeEntry(
            id: "entry",
            remoteID: "entry",
            start: start,
            end: start.addingTimeInterval(duration),
            projectID: nil,
            projectName: nil,
            clientName: nil,
            note: "",
            tags: [],
            billable: true,
            syncState: .synced
        )
    }

    private func fixture(_ json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    private func inputSchema(properties: [String], required: [String] = []) -> Value {
        var object: [String: Value] = [
            "type": .string("object"),
            "properties": .object(Dictionary(uniqueKeysWithValues: properties.map {
                ($0, .object(["type": .string("boolean")]))
            })),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty {
            object["required"] = .array(required.map { .string($0) })
        }
        return .object(object)
    }

    private func assertInvalidResponse<T>(
        contains expectedText: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        do {
            _ = try operation()
            XCTFail("Expected an invalid-response error.", file: file, line: line)
        } catch TimenBarError.invalidResponse(let message) {
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains(expectedText),
                "Expected '\(message)' to contain '\(expectedText)'.",
                file: file,
                line: line
            )
        } catch {
            XCTFail("Expected invalidResponse, got \(error).", file: file, line: line)
        }
    }
}
