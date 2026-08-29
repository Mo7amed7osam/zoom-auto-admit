import Foundation
import XCTest
@testable import ZoomAutoAdmitCore

/// Everything the model returns is untrusted input. These tests are mostly
/// about what the app refuses to believe.
final class AIMatchValidationTests: XCTestCase {
    private let students = [
        Student(officialName: "Mohamed Ahmed Hassan"),
        Student(officialName: "Sara Mostafa Ali")
    ]

    private func observation(_ name: String) -> ParticipantObservation {
        ParticipantObservation(
            rawName: name,
            normalizedName: NameNormalizer.normalize(name),
            observedAt: [Date()]
        )
    }

    private func ids() -> [String: UUID] {
        ["s0": students[0].id, "s1": students[1].id]
    }

    func testValidProposalIsAccepted() {
        let observed = [observation("Mohamed Hassan")]
        let response = AIMatchResponse(
            matches: [AIMatchProposal(studentId: "s0", zoomName: "Mohamed Hassan", confidence: 0.94, reason: "family name")],
            unresolvedZoomNames: []
        )

        let result = AIMatchValidator.validate(
            response, students: students, observations: observed, studentIDs: ids()
        )

        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches[0].studentID, students[0].id)
        XCTAssertEqual(result.matches[0].confidence, 0.94)
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func testHallucinatedStudentIDIsRejected() {
        let response = AIMatchResponse(
            matches: [AIMatchProposal(studentId: "nobody", zoomName: "Mohamed Hassan", confidence: 0.99, reason: nil)],
            unresolvedZoomNames: nil
        )
        let result = AIMatchValidator.validate(
            response, students: students, observations: [observation("Mohamed Hassan")], studentIDs: ids()
        )

        XCTAssertTrue(result.matches.isEmpty)
        XCTAssertEqual(result.rejected.count, 1)
    }

    /// The absolute rule: the model cannot invent an attendee.
    func testZoomNameThatWasNeverObservedIsRejected() {
        let response = AIMatchResponse(
            matches: [AIMatchProposal(studentId: "s0", zoomName: "Somebody Who Never Joined", confidence: 0.99, reason: nil)],
            unresolvedZoomNames: nil
        )
        let result = AIMatchValidator.validate(
            response, students: students, observations: [observation("Mohamed Hassan")], studentIDs: ids()
        )

        XCTAssertTrue(result.matches.isEmpty, "no observation, no attendance")
        XCTAssertTrue(result.rejected[0].contains("not observed"))
    }

    func testDuplicateStudentAssignmentIsRejected() {
        let observed = [observation("Mohamed Hassan"), observation("M. Hassan")]
        let response = AIMatchResponse(
            matches: [
                AIMatchProposal(studentId: "s0", zoomName: "Mohamed Hassan", confidence: 0.9, reason: nil),
                AIMatchProposal(studentId: "s0", zoomName: "M. Hassan", confidence: 0.8, reason: nil)
            ],
            unresolvedZoomNames: nil
        )
        let result = AIMatchValidator.validate(
            response, students: students, observations: observed, studentIDs: ids()
        )

        XCTAssertEqual(result.matches.count, 1, "one student cannot be present twice over")
    }

    func testDuplicateZoomNameAssignmentIsRejected() {
        let observed = [observation("Mohamed Hassan")]
        let response = AIMatchResponse(
            matches: [
                AIMatchProposal(studentId: "s0", zoomName: "Mohamed Hassan", confidence: 0.9, reason: nil),
                AIMatchProposal(studentId: "s1", zoomName: "Mohamed Hassan", confidence: 0.7, reason: nil)
            ],
            unresolvedZoomNames: nil
        )
        let result = AIMatchValidator.validate(
            response, students: students, observations: observed, studentIDs: ids()
        )

        XCTAssertEqual(result.matches.count, 1, "one Zoom identity cannot make two students present")
        XCTAssertEqual(result.matches[0].studentID, students[0].id)
    }

    func testOutOfRangeConfidenceIsRejected() {
        for bad in [1.5, -0.2, Double.nan, Double.infinity] {
            let response = AIMatchResponse(
                matches: [AIMatchProposal(studentId: "s0", zoomName: "Mohamed Hassan", confidence: bad, reason: nil)],
                unresolvedZoomNames: nil
            )
            let result = AIMatchValidator.validate(
                response, students: students, observations: [observation("Mohamed Hassan")], studentIDs: ids()
            )
            XCTAssertTrue(result.matches.isEmpty, "confidence \(bad) must be rejected")
        }
    }

    // MARK: Decoding

    func testJSONInsideACodeFenceIsDecoded() throws {
        let text = """
        Here you go:
        ```json
        {"matches":[{"studentId":"s0","zoomName":"Mohamed Hassan","confidence":0.9,"reason":"x"}],
         "unresolvedZoomNames":[]}
        ```
        """
        let decoded = try AIMatchValidator.decode(text)
        XCTAssertEqual(decoded.matches.count, 1)
    }

    func testProseWithoutJSONIsRejected() {
        XCTAssertThrowsError(try AIMatchValidator.decode("I think Mohamed was probably there."))
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(try AIMatchValidator.decode("{\"matches\": [ }"))
    }

    func testMissingRequiredFieldIsRejected() {
        XCTAssertThrowsError(try AIMatchValidator.decode("{\"matches\":[{\"studentId\":\"s0\"}]}"))
    }
}

final class OpenRouterRequestTests: XCTestCase {
    func testOnlyUnresolvedNamesAreIncluded() {
        let request = AIMatchRequest(
            students: [.init(id: "s0", officialName: "Mohamed Ahmed Hassan")],
            zoomNames: ["Mohamed Hassan"]
        )
        let prompt = OpenRouterClient.prompt(for: request)

        XCTAssertTrue(prompt.contains("Mohamed Ahmed Hassan"))
        XCTAssertTrue(prompt.contains("Mohamed Hassan"))
        // Nothing about the rest of the app may travel.
        for forbidden in ["password", "token", "api", "schedule", "zoommtg", "Bearer"] {
            XCTAssertFalse(prompt.lowercased().contains(forbidden.lowercased()), "prompt leaked \(forbidden)")
        }
    }

    func testNothingIsSentWhenThereIsNothingAmbiguous() async {
        var called = false
        let client = OpenRouterClient(apiKeyProvider: {
            called = true
            return "should-not-be-read"
        })

        let empty = AIMatchRequest(students: [], zoomNames: [])
        XCTAssertFalse(empty.isWorthSending)

        let result = await client.proposeMatches(for: empty)
        guard case .success(let response) = result else { return XCTFail("expected success") }
        XCTAssertTrue(response.matches.isEmpty)
        XCTAssertFalse(called, "no key is even read when there is nothing to ask")
    }

    func testMissingKeyIsReportedNotCrashed() async {
        let client = OpenRouterClient(apiKeyProvider: { nil })
        let result = await client.proposeMatches(
            for: AIMatchRequest(students: [.init(id: "s0", officialName: "A")], zoomNames: ["B"])
        )

        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .noAPIKey)
    }

    func testResponseContentExtraction() {
        let body = """
        {"choices":[{"message":{"role":"assistant","content":"{\\"matches\\":[]}"}}]}
        """
        XCTAssertEqual(OpenRouterClient.extractContent(from: Data(body.utf8)), "{\"matches\":[]}")
        XCTAssertNil(OpenRouterClient.extractContent(from: Data("{}".utf8)))
    }

    func testRetriesAreBounded() {
        XCTAssertEqual(OpenRouterClient.Configuration(maxAttempts: 99).maxAttempts, 3)
        XCTAssertEqual(OpenRouterClient.Configuration(maxAttempts: 0).maxAttempts, 1)
    }

    /// The key must never appear anywhere a human or a log could see it.
    func testRedactionNeverRevealsTheKey() {
        let key = "sk-or-v1-abcdefghijklmnop1234"
        let redacted = APIKeyStore.redacted(key)

        XCTAssertFalse(redacted.contains("abcdefghijklmnop"))
        XCTAssertTrue(redacted.hasSuffix("1234"))
        XCTAssertEqual(APIKeyStore.redacted(nil), "not set")
        XCTAssertEqual(APIKeyStore.redacted("short"), "not set")
    }
}

final class AIReconciliationTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func observation(_ name: String) -> ParticipantObservation {
        ParticipantObservation(
            rawName: name,
            normalizedName: NameNormalizer.normalize(name),
            observedAt: [base, base.addingTimeInterval(600)]
        )
    }

    private func session(
        students: [Student],
        observations: [ParticipantObservation]
    ) -> AttendanceSession {
        AttendanceReconciler.reconcile(
            session: AttendanceSession(
                groupID: UUID(),
                groupName: "Group A",
                meetingName: "Week 2",
                startedAt: base,
                rosterSnapshot: students,
                observations: observations
            ),
            autoAcceptConfidence: 0.9
        )
    }

    /// Exactly matched students never reach the network.
    func testOnlyUnresolvedStudentsAndFreeNamesAreSent() {
        let matched = Student(officialName: "Sara Mostafa Ali")
        let unmatched = Student(officialName: "Ahmed Tarek")
        let current = session(
            students: [matched, unmatched],
            observations: [observation("Sara Mostafa Ali"), observation("Ahmed's iPhone")]
        )

        let (request, ids) = AIReconciliation.request(for: current)

        // Sara matched exactly and never leaves the machine; only the device
        // name and the student it might belong to are worth asking about.
        XCTAssertEqual(request.students.map(\.officialName), ["Ahmed Tarek"])
        XCTAssertEqual(request.zoomNames, ["Ahmed's iPhone"])
        XCTAssertEqual(ids.count, 1)
        XCTAssertFalse(request.students.contains { $0.officialName == "Sara Mostafa Ali" })
    }

    /// A device name is the classic case local matching cannot settle.
    func testConfidentProposalBecomesPresent() {
        let student = Student(officialName: "Ahmed Tarek")
        let current = session(students: [student], observations: [observation("Ahmed's iPhone")])
        let (_, ids) = AIReconciliation.request(for: current)
        XCTAssertNotEqual(current.records[0].status, .present, "local matching must not have settled this")

        let summary = AIReconciliation.apply(
            AIMatchResponse(
                matches: [AIMatchProposal(studentId: "s0", zoomName: "Ahmed's iPhone", confidence: 0.96, reason: "known device")],
                unresolvedZoomNames: []
            ),
            to: current,
            ids: ids,
            autoAcceptConfidence: 0.9
        )

        XCTAssertEqual(summary.appliedCount, 1)
        XCTAssertEqual(summary.session.records[0].status, .present)
        XCTAssertEqual(summary.session.records[0].matchSource, .ai)
        XCTAssertEqual(summary.session.records[0].confidence, 0.96)
        XCTAssertEqual(summary.session.records[0].matchedZoomName, "Ahmed's iPhone")
    }

    /// Below the threshold is a question for a human, not an answer.
    func testLowConfidenceProposalBecomesNeedsReview() {
        let student = Student(officialName: "Ahmed Tarek")
        let current = session(students: [student], observations: [observation("Ahmed's iPhone")])
        let (_, ids) = AIReconciliation.request(for: current)

        let summary = AIReconciliation.apply(
            AIMatchResponse(
                matches: [AIMatchProposal(studentId: "s0", zoomName: "Ahmed's iPhone", confidence: 0.63, reason: "first name only")],
                unresolvedZoomNames: []
            ),
            to: current,
            ids: ids,
            autoAcceptConfidence: 0.9
        )

        XCTAssertEqual(summary.appliedCount, 0)
        XCTAssertEqual(summary.reviewCount, 1)
        XCTAssertEqual(summary.session.records[0].status, .needsReview)
    }

    func testManualDecisionsAreNeverOverwrittenByAI() {
        let student = Student(officialName: "Ahmed Tarek")
        var current = session(students: [student], observations: [observation("Ahmed's iPhone")])
        current = AttendanceReconciler.applyManualMatch(
            session: current,
            studentID: student.id,
            observationID: nil,
            status: .absent
        )

        let summary = AIReconciliation.apply(
            AIMatchResponse(
                matches: [AIMatchProposal(studentId: "s0", zoomName: "Ahmed's iPhone", confidence: 0.99, reason: nil)],
                unresolvedZoomNames: []
            ),
            to: current,
            ids: ["s0": student.id],
            autoAcceptConfidence: 0.9
        )

        XCTAssertEqual(summary.session.records[0].status, .absent)
        XCTAssertTrue(summary.session.records[0].isManual)
    }

    /// AI being down must cost nothing that was already worked out locally.
    func testUnavailableAIPreservesLocalResults() {
        let matched = Student(officialName: "Sara Mostafa Ali")
        let unmatched = Student(officialName: "Ahmed Tarek")
        let current = session(
            students: [matched, unmatched],
            observations: [observation("Sara Mostafa Ali"), observation("Ahmed's iPhone")]
        )

        let summary = AIReconciliation.unavailable(.network("offline"), session: current)

        XCTAssertTrue(summary.aiWasUnavailable)
        XCTAssertEqual(summary.session.records.first { $0.studentName == "Sara Mostafa Ali" }?.status, .present)
        XCTAssertEqual(summary.appliedCount, 0)
    }

    func testHallucinatedProposalsAreReportedAndDiscarded() {
        let student = Student(officialName: "Ahmed Tarek")
        let current = session(students: [student], observations: [observation("Ahmed's iPhone")])

        let summary = AIReconciliation.apply(
            AIMatchResponse(
                matches: [AIMatchProposal(studentId: "s0", zoomName: "Never Joined", confidence: 0.99, reason: nil)],
                unresolvedZoomNames: []
            ),
            to: current,
            ids: ["s0": student.id],
            autoAcceptConfidence: 0.9
        )

        XCTAssertEqual(summary.appliedCount, 0)
        XCTAssertEqual(summary.rejected.count, 1)
        XCTAssertNotEqual(summary.session.records[0].status, .present)
    }
}
