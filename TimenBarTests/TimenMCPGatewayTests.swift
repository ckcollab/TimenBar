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
                userFilterWasEmitted: true
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
                userFilterWasEmitted: false
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
                userFilterWasEmitted: true
            )
        }
    }

    func testOwnerlessEntryIsRejectedWithoutServerFilter() throws {
        let response = try ownerlessEntryResponse()

        assertInvalidResponse(contains: "no recognized server-side user filter") {
            try TimenMCPResponseParser.entries(
                from: response,
                currentAccountID: "42",
                userFilterWasEmitted: false
            )
        }
    }

    func testOwnerlessEntryIsAcceptedWithServerFilter() throws {
        let response = try ownerlessEntryResponse()

        let entries = try TimenMCPResponseParser.entries(
            from: response,
            currentAccountID: "42",
            userFilterWasEmitted: true
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
            userFilterWasEmitted: false
        )

        XCTAssertEqual(entries.map(\.id), ["100"])
    }

    private func ownerlessEntryResponse() throws -> Value {
        try fixture(
            #"{"entries":[{"id":"100","start":"2026-08-20T16:00:00Z","end":"2026-08-20T17:00:00Z"}]}"#
        )
    }

    private func fixture(_ json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }

    private func inputSchema(properties: [String]) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(Dictionary(uniqueKeysWithValues: properties.map {
                ($0, .object(["type": .string("boolean")]))
            })),
            "additionalProperties": .bool(false),
        ])
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
