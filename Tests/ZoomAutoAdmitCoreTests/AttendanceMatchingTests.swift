import Foundation
import XCTest
import ZoomAXSupport
@testable import ZoomAutoAdmitCore

final class NameNormalizerTests: XCTestCase {
    func testWhitespaceAndCaseAreNormalized() {
        XCTAssertEqual(NameNormalizer.normalize("  Mohamed   Ahmed  "), "mohamed ahmed")
        XCTAssertEqual(NameNormalizer.normalize("MOHAMED AHMED"), "mohamed ahmed")
    }

    func testRoleSuffixesAreRemovedDefensively() {
        XCTAssertEqual(NameNormalizer.normalize("Mohamed Ahmed (Guest)"), "mohamed ahmed")
        XCTAssertEqual(NameNormalizer.normalize("eyouth coordinator (Host, me)"), "eyouth coordinator")
    }

    /// Arabic letter shapes vary freely in everyday typing; leaving them
    /// distinct would split one student across two spellings.
    func testArabicLetterVariantsAreUnified() {
        XCTAssertEqual(
            NameNormalizer.normalize("أحمد"),
            NameNormalizer.normalize("احمد")
        )
        XCTAssertEqual(
            NameNormalizer.normalize("يحيى"),
            NameNormalizer.normalize("يحيي")
        )
        XCTAssertEqual(
            NameNormalizer.normalize("فاطمة"),
            NameNormalizer.normalize("فاطمه")
        )
        XCTAssertEqual(NameNormalizer.normalize("مُحَمَّد"), NameNormalizer.normalize("محمد"))
    }

    /// The opposite failure matters just as much: different people must not
    /// collapse into the same normalized name.
    func testDifferentPeopleDoNotCollapse() {
        XCTAssertNotEqual(
            NameNormalizer.normalize("Mohamed Ahmed"),
            NameNormalizer.normalize("Mahmoud Ahmed")
        )
        XCTAssertNotEqual(
            NameNormalizer.normalize("Sara Ali"),
            NameNormalizer.normalize("Sara Alaa")
        )
        XCTAssertNotEqual(NameNormalizer.normalize("عمر خالد"), NameNormalizer.normalize("عمرو خالد"))
    }

    func testDeviceNamesAreRecognised() {
        for name in ["iPhone", "Ahmed's iPhone", "Galaxy S23", "iPad", "Zoom User"] {
            XCTAssertTrue(NameNormalizer.looksLikeDeviceName(name), "\(name) should look like a device")
        }
        XCTAssertFalse(NameNormalizer.looksLikeDeviceName("Mohamed Ahmed Hassan"))
    }

    func testLowSignalNames() {
        XCTAssertTrue(NameNormalizer.isLowSignal(""))
        XCTAssertTrue(NameNormalizer.isLowSignal("12345"))
        XCTAssertTrue(NameNormalizer.isLowSignal("A"))
        XCTAssertFalse(NameNormalizer.isLowSignal("Ahmed"))
    }
}

final class DeterministicMatcherTests: XCTestCase {
    private func student(_ name: String, aliases: [String] = []) -> Student {
        Student(officialName: name, aliases: aliases)
    }

    private func observation(_ name: String) -> ParticipantObservation {
        ParticipantObservation(
            rawName: name,
            normalizedName: NameNormalizer.normalize(name),
            firstSeen: Date(timeIntervalSince1970: 0),
            lastSeen: Date(timeIntervalSince1970: 60)
        )
    }

    private func match(
        _ students: [Student],
        _ observations: [ParticipantObservation],
        autoAccept: Double = 0.90
    ) -> MatchingOutcome {
        DeterministicMatcher.match(
            students: students,
            observations: observations,
            autoAcceptConfidence: autoAccept
        )
    }

    func testExactNameIsAcceptedWithoutAI() {
        let target = student("Mohamed Ahmed Hassan")
        let seen = observation("Mohamed Ahmed Hassan")
        let outcome = match([target], [seen])

        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertEqual(outcome.accepted.first?.source, .exact)
        XCTAssertEqual(outcome.accepted.first?.score, 1.0)
        XCTAssertTrue(outcome.review.isEmpty)
    }

    func testLearnedAliasResolvesWithoutAI() {
        let target = student("Mohamed Ahmed Hassan", aliases: ["Mohamed's iPhone"])
        let outcome = match([target], [observation("Mohamed's iPhone")])

        XCTAssertEqual(outcome.accepted.first?.source, .alias)
        XCTAssertEqual(outcome.accepted.first?.score, 1.0)
    }

    /// The everyday case: people drop their middle name.
    func testDroppedMiddleNameMatchesDeterministically() {
        let target = student("Mohamed Ahmed Hassan")
        let outcome = match([target], [observation("Mohamed Hassan")])

        XCTAssertEqual(outcome.accepted.count, 1, "should not need AI")
        XCTAssertEqual(outcome.accepted.first?.source, .token)
    }

    func testCaseAndSpacingDifferencesMatch() {
        let outcome = match([student("Sara Mostafa Ali")], [observation("  sara   mostafa ali ")])
        XCTAssertEqual(outcome.accepted.count, 1)
    }

    /// A device name may be a student, but it is not evidence, so it must not
    /// be recorded as present on its own.
    func testDeviceNameNeverAutoAccepts() {
        let target = student("Ahmed Tarek")
        let outcome = match([target], [observation("Ahmed's iPhone")])

        XCTAssertTrue(outcome.accepted.isEmpty, "a device name must not be auto-accepted")
        XCTAssertLessThanOrEqual(
            outcome.review.first?.score ?? 0,
            DeterministicMatcher.deviceNameCeiling
        )
    }

    func testSharedFamilyNameAloneIsNotEnough() {
        let target = student("Mohamed Ahmed Hassan")
        let outcome = match([target], [observation("Youssef Hassan")])

        XCTAssertTrue(outcome.accepted.isEmpty, "a shared family name is weak evidence")
    }

    func testUnrelatedNameIsNotMatched() {
        let outcome = match([student("Mohamed Ahmed Hassan")], [observation("Omar Khaled")])
        XCTAssertTrue(outcome.accepted.isEmpty)
        XCTAssertTrue(outcome.review.isEmpty)
        XCTAssertEqual(outcome.unmatchedObservationIDs.count, 1)
    }

    /// One Zoom name must not mark two students present.
    func testOneObservationCannotSatisfyTwoStudents() {
        let first = student("Mohamed Ahmed Hassan")
        let second = student("Mohamed Ahmed Hussein")
        let outcome = match([first, second], [observation("Mohamed Ahmed Hassan")])

        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertEqual(outcome.accepted.first?.studentID, first.id)
        XCTAssertEqual(outcome.unmatchedStudentIDs.count, 1)
    }

    /// And one student must not consume two Zoom identities.
    func testOneStudentCannotConsumeTwoObservations() {
        let target = student("Mohamed Ahmed Hassan")
        let outcome = match([target], [observation("Mohamed Ahmed Hassan"), observation("Mohamed Hassan")])

        XCTAssertEqual(outcome.accepted.count, 1)
        XCTAssertEqual(outcome.unmatchedObservationIDs.count + outcome.review.count, 1)
    }

    /// The strongest pairing wins, rather than whichever was compared first.
    func testStrongestPairingIsChosen() {
        let hassan = student("Mohamed Ahmed Hassan")
        let hussein = student("Mohamed Ahmed Hussein")
        let outcome = match([hassan, hussein], [observation("Mohamed Ahmed Hussein"), observation("Mohamed Ahmed Hassan")])

        XCTAssertEqual(outcome.accepted.count, 2)
        for candidate in outcome.accepted {
            let student = [hassan, hussein].first { $0.id == candidate.studentID }
            XCTAssertEqual(candidate.source, .exact, "\(student?.officialName ?? "") should match exactly")
        }
    }

    func testArabicRosterMatchesArabicZoomName() {
        let target = student("عبدالرحمن محمد علي")
        let outcome = match([target], [observation("عبد الرحمن محمد على")])
        XCTAssertEqual(outcome.accepted.count + outcome.review.count, 1)
    }

    func testAbsentStudentIsSimplyUnmatched() {
        let present = student("Mohamed Ahmed Hassan")
        let absent = student("Omar Khaled")
        let outcome = match([present, absent], [observation("Mohamed Ahmed Hassan")])

        XCTAssertEqual(outcome.unmatchedStudentIDs, [absent.id])
    }
}

final class ParticipantRecorderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func group(ignoring ignored: [String] = []) -> StudentGroup {
        StudentGroup(name: "Group A", students: [], ignoredParticipantNames: ignored)
    }

    private func row(_ name: String, roles: Set<ZoomAXSupport.ParticipantRole> = []) -> ZoomAXSupport.ParticipantRow {
        ZoomAXSupport.ParticipantRow(
            rawText: name,
            displayName: name,
            roles: roles,
            indexPath: [0]
        )
    }

    private func readout(
        _ rows: [ZoomAXSupport.ParticipantRow],
        waiting: [ZoomAXSupport.ParticipantRow] = []
    ) -> ZoomAXSupport.ParticipantsReadout {
        ZoomAXSupport.ParticipantsReadout(
            listAvailable: true,
            admitted: rows,
            waiting: waiting,
            reportedCount: rows.count
        )
    }

    func testParticipantsAreRecordedWithTimestamps() {
        let recorder = ParticipantRecorder(group: group())
        recorder.record(readout([row("Mohamed Ahmed")]), at: start)
        recorder.record(readout([row("Mohamed Ahmed")]), at: start.addingTimeInterval(60))

        XCTAssertEqual(recorder.observations.count, 1)
        let observation = recorder.observations[0]
        XCTAssertEqual(observation.rawName, "Mohamed Ahmed")
        XCTAssertEqual(observation.firstSeen, start)
        XCTAssertEqual(observation.lastSeen, start.addingTimeInterval(60))
        XCTAssertTrue(observation.currentlyPresent)
        XCTAssertEqual(observation.joinCount, 1)
    }

    /// The teacher is not on their own register.
    func testHostIsNotRecordedAsAStudent() {
        let recorder = ParticipantRecorder(group: group())
        recorder.record(readout([
            row("eyouth coordinator", roles: [.host, .me]),
            row("Mohamed Ahmed", roles: [.guest])
        ]), at: start)

        XCTAssertEqual(recorder.observations.map(\.rawName), ["Mohamed Ahmed"])
    }

    func testIgnoredNamesAreNotRecorded() {
        let recorder = ParticipantRecorder(group: group(ignoring: ["Training Coordinator"]))
        recorder.record(readout([row("training coordinator"), row("Sara Ali")]), at: start)

        XCTAssertEqual(recorder.observations.map(\.rawName), ["Sara Ali"])
    }

    /// Waiting Room entries are not attendance until admitted.
    func testWaitingRoomEntriesAreNotAttendance() {
        let recorder = ParticipantRecorder(group: group())
        recorder.record(readout([], waiting: [row("Ahmed Tarek")]), at: start)

        XCTAssertTrue(recorder.observations.isEmpty)
    }

    /// Leaving and rejoining is one student with two intervals.
    func testRejoiningDoesNotCreateASecondAttendee() {
        let recorder = ParticipantRecorder(group: group())
        recorder.record(readout([row("Mohamed Ahmed")]), at: start)
        recorder.record(readout([]), at: start.addingTimeInterval(120))
        recorder.record(readout([row("Mohamed Ahmed")]), at: start.addingTimeInterval(300))
        recorder.finish(at: start.addingTimeInterval(600))

        XCTAssertEqual(recorder.observations.count, 1)
        XCTAssertEqual(recorder.observations[0].joinCount, 2)
        XCTAssertFalse(recorder.observations[0].currentlyPresent)
    }

    /// The failure that would mark a whole class absent: a list that cannot be
    /// read is not a list with nobody in it.
    func testUnavailableListDoesNotMarkEveryoneGone() {
        let recorder = ParticipantRecorder(group: group())
        recorder.record(readout([row("Mohamed Ahmed")]), at: start)
        recorder.record(.unavailable, at: start.addingTimeInterval(60))

        XCTAssertEqual(recorder.observations.count, 1)
        XCTAssertTrue(recorder.observations[0].currentlyPresent, "an unreadable list says nothing")
        XCTAssertEqual(recorder.unavailableReads, 1)
        XCTAssertEqual(recorder.successfulReads, 1)
    }

    func testLateJoinerIsRecorded() {
        let recorder = ParticipantRecorder(group: group())
        recorder.record(readout([row("Mohamed Ahmed")]), at: start)
        recorder.record(readout([row("Mohamed Ahmed"), row("Sara Ali")]), at: start.addingTimeInterval(1_800))

        XCTAssertEqual(recorder.observations.count, 2)
        let late = recorder.observations.first { $0.rawName == "Sara Ali" }
        XCTAssertEqual(late?.firstSeen, start.addingTimeInterval(1_800))
    }

    func testDurationAccumulatesAcrossIntervals() {
        let recorder = ParticipantRecorder(group: group())
        recorder.record(readout([row("Mohamed Ahmed")]), at: start)
        recorder.record(readout([row("Mohamed Ahmed")]), at: start.addingTimeInterval(600))
        recorder.finish(at: start.addingTimeInterval(600))

        XCTAssertEqual(recorder.observations[0].totalDuration, 600)
    }
}
