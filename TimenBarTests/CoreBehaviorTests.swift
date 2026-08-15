import CryptoKit
import XCTest
@testable import TimenBar

final class CoreBehaviorTests: XCTestCase {
    func testPKCEChallengeUsesRFC7636Base64URL() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(OAuthSecurity.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testOAuthCallbackRequiresMatchingState() throws {
        let valid = URL(string: "http://127.0.0.1:4567/oauth/callback?code=abc&state=expected")!
        XCTAssertEqual(try OAuthSecurity.validateCallback(valid, expectedState: "expected"), "abc")

        let invalid = URL(string: "http://127.0.0.1:4567/oauth/callback?code=abc&state=attacker")!
        XCTAssertThrowsError(try OAuthSecurity.validateCallback(invalid, expectedState: "expected"))
    }

    func testTokenRefreshWindow() {
        let fresh = OAuthTokenSet(accessToken: "a", tokenType: "Bearer", expiresAt: .now.addingTimeInterval(600))
        let expiring = OAuthTokenSet(accessToken: "a", tokenType: "Bearer", expiresAt: .now.addingTimeInterval(30))
        XCTAssertFalse(fresh.needsRefresh)
        XCTAssertTrue(expiring.needsRefresh)
    }

    func testRequiredMCPToolValidation() {
        let missing = TimenToolContract.missing(from: RequiredTimenTool.names.subtracting(["timen_delete_time_entry"]))
        XCTAssertEqual(missing, ["timen_delete_time_entry"])
        XCTAssertTrue(TimenToolContract.missing(from: RequiredTimenTool.names).isEmpty)
    }

    func testIdleThresholdPromptsOnceAndRearmsAfterActivity() {
        var policy = IdlePromptPolicy(threshold: 600)
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(policy.observe(idleSeconds: 599, now: now))
        XCTAssertEqual(policy.observe(idleSeconds: 600, now: now), now.addingTimeInterval(-600))
        XCTAssertNil(policy.observe(idleSeconds: 900, now: now))
        XCTAssertNil(policy.observe(idleSeconds: 0, now: now))
        XCTAssertNotNil(policy.observe(idleSeconds: 601, now: now))
    }

    func testContinueSuppressesUntilActivity() {
        var policy = IdlePromptPolicy(threshold: 300)
        policy.suppressUntilActivity()
        XCTAssertNil(policy.observe(idleSeconds: 900, now: .now))
        XCTAssertNil(policy.observe(idleSeconds: 0, now: .now))
        XCTAssertNotNil(policy.observe(idleSeconds: 301, now: .now))
    }

    func testIdleBeforeTimerStartDoesNotImmediatelyPrompt() {
        let timerStart = Date(timeIntervalSince1970: 10_000)
        var policy = IdlePromptPolicy(threshold: 600, notBefore: timerStart)

        XCTAssertNil(policy.observe(idleSeconds: 3_600, now: timerStart))
        XCTAssertNil(policy.observe(idleSeconds: 4_199, now: timerStart.addingTimeInterval(599)))
        XCTAssertEqual(
            policy.observe(idleSeconds: 4_200, now: timerStart.addingTimeInterval(600)),
            timerStart
        )
    }

    func testDurationAcrossDaylightSavingBoundaryUsesAbsoluteTime() throws {
        let formatter = ISO8601DateFormatter()
        let start = try XCTUnwrap(formatter.date(from: "2026-03-08T01:30:00-08:00"))
        let end = try XCTUnwrap(formatter.date(from: "2026-03-08T03:30:00-07:00"))
        let entry = TimeEntry(
            id: "dst", remoteID: "dst", start: start, end: end, projectID: nil,
            projectName: nil, clientName: nil, note: "", tags: [], billable: false, syncState: .synced
        )
        XCTAssertEqual(entry.duration, 3_600)
    }

    func testTimenClockDurations() {
        XCTAssertEqual(TimenDurationParser.parseClock("4:25:48"), 15_948)
        XCTAssertEqual(TimenDurationParser.parseClock("0:30:00"), 1_800)
        XCTAssertEqual(TimenDurationParser.parseClock("4:26"), 15_960)
    }

    func testEntryDisplayOrderUsesCreationIDNotUpdatedDuration() {
        let sharedStart = Date(timeIntervalSince1970: 10_000)
        let older = TimeEntry(
            id: "100", remoteID: "100", start: sharedStart, end: sharedStart.addingTimeInterval(60),
            projectID: nil, projectName: nil, clientName: nil, note: "Older", tags: [],
            billable: false, syncState: .synced
        )
        let newer = TimeEntry(
            id: "101", remoteID: "101", start: sharedStart, end: sharedStart.addingTimeInterval(30),
            projectID: nil, projectName: nil, clientName: nil, note: "Newer", tags: [],
            billable: false, syncState: .synced
        )
        var updatedOlder = older
        updatedOlder.end = sharedStart.addingTimeInterval(10_000)

        XCTAssertEqual([updatedOlder, newer].sorted(by: TimeEntry.newestCreatedFirst).map(\.id), ["101", "100"])
    }
}
