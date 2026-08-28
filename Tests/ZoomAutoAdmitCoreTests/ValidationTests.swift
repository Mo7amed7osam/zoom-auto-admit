import Foundation
import XCTest
@testable import ZoomAutoAdmitCore

/// Validation exists because an invalid configuration doesn't fail when it is
/// saved — it fails hours later, at 6:00 PM, with "No saved Zoom account
/// matches". These rules keep it from being persisted at all.
final class ValidationTests: XCTestCase {
    private func profile(
        name: String = "Personal",
        identifier: String = "mohamed.hosam2310@gmail.com"
    ) -> ZoomAccountProfile {
        ZoomAccountProfile(name: name, accountIdentifier: identifier)
    }

    private func schedule(
        profileID: UUID,
        name: String = "Saturday DEPI",
        recurrence: ScheduleRecurrence = .selectedWeekdays([.saturday]),
        meeting: MeetingReference = MeetingReference(name: "Week 2", kind: .meetingID("123 4567 8901"))
    ) -> ZoomSchedule {
        ZoomSchedule(
            name: name,
            recurrence: recurrence,
            startTime: TimeOfDay(hour: 18, minute: 0),
            accountProfileID: profileID,
            meeting: meeting
        )
    }

    // MARK: Account profiles

    /// The live bug: choosing a detected account left the stored email empty and
    /// the profile was saved as `personal <>`.
    func testProfileWithEmptyAccountIsInvalid() {
        let issues = ScheduleValidation.validate(profile(identifier: ""))
        XCTAssertEqual(issues.map(\.field), [.accountIdentifier])
        XCTAssertEqual(issues.first?.message, "Select a Zoom account")
        XCTAssertFalse(ScheduleValidation.isValid(profile(identifier: "")))
    }

    func testProfileWithoutANameIsInvalid() {
        let issues = ScheduleValidation.validate(profile(name: "   "))
        XCTAssertTrue(issues.contains { $0.field == .name })
    }

    func testProfileRequiresSomethingThatLooksLikeAnEmail() {
        for bad in ["personal", "not an email", "@example.com", "a@b", "a@@b.com", "a b@c.com"] {
            XCTAssertFalse(
                ScheduleValidation.isValid(profile(identifier: bad)),
                "\(bad) should be rejected"
            )
        }
        for good in ["a@b.com", "depi+11@eyouthlearning.com", "depi4.2025_45@teml.net"] {
            XCTAssertTrue(
                ScheduleValidation.isValid(profile(identifier: good)),
                "\(good) should be accepted"
            )
        }
    }

    func testValidProfileHasNoIssues() {
        XCTAssertTrue(ScheduleValidation.validate(profile()).isEmpty)
    }

    // MARK: Schedules

    func testScheduleRequiresAName() {
        let account = profile()
        let configuration = SchedulerConfiguration(accountProfiles: [account], schedules: [])
        let issues = ScheduleValidation.validate(
            schedule(profileID: account.id, name: "  "),
            in: configuration
        )
        XCTAssertTrue(issues.contains { $0.field == .name })
    }

    func testScheduleRequiresAnExistingAccountProfile() {
        let configuration = SchedulerConfiguration(accountProfiles: [], schedules: [])
        let issues = ScheduleValidation.validate(schedule(profileID: UUID()), in: configuration)
        XCTAssertTrue(issues.contains { $0.field == .account })
        XCTAssertEqual(issues.first { $0.field == .account }?.message, "Select a Zoom account")
    }

    func testSelectedWeekdaysRequiresAtLeastOneDay() {
        let account = profile()
        let configuration = SchedulerConfiguration(accountProfiles: [account], schedules: [])
        let issues = ScheduleValidation.validate(
            schedule(profileID: account.id, recurrence: .selectedWeekdays([])),
            in: configuration
        )
        XCTAssertTrue(issues.contains { $0.field == .weekdays })

        let daily = ScheduleValidation.validate(
            schedule(profileID: account.id, recurrence: .daily),
            in: configuration
        )
        XCTAssertFalse(daily.contains { $0.field == .weekdays }, "Daily needs no weekday selection")
    }

    func testMeetingIDIsRequiredForIDMeetingsOnly() {
        let account = profile()
        let configuration = SchedulerConfiguration(accountProfiles: [account], schedules: [])

        let missing = ScheduleValidation.validate(
            schedule(
                profileID: account.id,
                meeting: MeetingReference(name: "Week 2", kind: .meetingID("  "))
            ),
            in: configuration
        )
        XCTAssertTrue(missing.contains { $0.field == .meetingID })

        let instant = ScheduleValidation.validate(
            schedule(
                profileID: account.id,
                meeting: MeetingReference(name: "Personal", kind: .instantMeeting)
            ),
            in: configuration
        )
        XCTAssertFalse(instant.contains { $0.field == .meetingID })
    }

    func testMeetingNameIsRequired() {
        let account = profile()
        let configuration = SchedulerConfiguration(accountProfiles: [account], schedules: [])
        let issues = ScheduleValidation.validate(
            schedule(
                profileID: account.id,
                meeting: MeetingReference(name: "", kind: .instantMeeting)
            ),
            in: configuration
        )
        XCTAssertTrue(issues.contains { $0.field == .meetingName })
    }

    func testValidScheduleHasNoIssues() {
        let account = profile()
        let configuration = SchedulerConfiguration(accountProfiles: [account], schedules: [])
        XCTAssertTrue(ScheduleValidation.validate(schedule(profileID: account.id), in: configuration).isEmpty)
    }

    /// A configuration is only saveable when every part of it is valid.
    func testConfigurationValidityCoversProfilesAndSchedules() {
        let goodAccount = profile()
        let badAccount = profile(name: "Broken", identifier: "")

        let valid = SchedulerConfiguration(
            accountProfiles: [goodAccount],
            schedules: [schedule(profileID: goodAccount.id)]
        )
        XCTAssertTrue(ScheduleValidation.isValid(valid))

        let brokenProfile = SchedulerConfiguration(
            accountProfiles: [goodAccount, badAccount],
            schedules: [schedule(profileID: goodAccount.id)]
        )
        XCTAssertFalse(ScheduleValidation.isValid(brokenProfile))

        let brokenSchedule = SchedulerConfiguration(
            accountProfiles: [goodAccount],
            schedules: [schedule(profileID: UUID())]
        )
        XCTAssertFalse(ScheduleValidation.isValid(brokenSchedule))
    }

    func testMeetingSummaryReadsWellInLists() {
        let byID = MeetingReference(name: "Week 2 Saturday", kind: .meetingID("12345678901"))
        XCTAssertEqual(byID.summaryText, "Week 2 Saturday · 123 4567 8901")

        let personal = MeetingReference(name: "New meeting", kind: .instantMeeting)
        XCTAssertEqual(personal.summaryText, "New meeting · Personal meeting")

        let unset = MeetingReference(name: "Unset", kind: .meetingID(""))
        XCTAssertEqual(unset.summaryText, "Unset")
    }

    /// Regression test for a live failure: a full invite link was reduced to
    /// digits, so the host name's own digits were spliced onto the front and the
    /// wrong number was used.
    func testMeetingLinksAreParsedStructurallyNotByStrippingDigits() {
        XCTAssertEqual(
            MeetingReference.normalizedMeetingID("https://zoom.us/j/94698416251"),
            "94698416251"
        )
        XCTAssertEqual(
            MeetingReference.normalizedMeetingID("https://us05web.zoom.us/j/94698416251"),
            "94698416251",
            "the 05 in us05web must not end up in the meeting number"
        )
        XCTAssertEqual(
            MeetingReference.normalizedMeetingID("https://us02web.zoom.us/j/94698416251?pwd=aBc123"),
            "94698416251"
        )
        XCTAssertEqual(
            MeetingReference.normalizedMeetingID("zoommtg://zoom.us/join?confno=94698416251"),
            "94698416251"
        )
        XCTAssertEqual(MeetingReference.normalizedMeetingID("https://zoom.us/s/94698416251"), "94698416251")
    }

    func testPlainMeetingNumbersStillWork() {
        XCTAssertEqual(MeetingReference.normalizedMeetingID("946 9841 6251"), "94698416251")
        XCTAssertEqual(MeetingReference.normalizedMeetingID("946-9841-6251"), "94698416251")
        XCTAssertEqual(MeetingReference.normalizedMeetingID("94698416251"), "94698416251")
    }

    func testUnparseableLinkYieldsNothingRatherThanGarbage() {
        // Better to fail validation than to open some other meeting.
        XCTAssertEqual(MeetingReference.normalizedMeetingID("https://zoom.us/my/someroom"), "")
        XCTAssertEqual(MeetingReference.normalizedMeetingID("https://example.com/nothing"), "")
    }

    func testPasscodeIsTakenFromAnInviteLink() {
        XCTAssertEqual(
            MeetingReference.passcode(from: "https://us02web.zoom.us/j/94698416251?pwd=aBc123xyz"),
            "aBc123xyz"
        )
        XCTAssertNil(MeetingReference.passcode(from: "https://zoom.us/j/94698416251"))
        XCTAssertNil(MeetingReference.passcode(from: "94698416251"))
    }

    func testPasscodeSurvivesPersistence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-pwd-\(UUID().uuidString)")
            .appendingPathComponent("schedules.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let account = profile()
        let meeting = MeetingReference(
            name: "Recurring",
            kind: .meetingID("https://zoom.us/j/94698416251"),
            passcode: "aBc123"
        )
        let configuration = SchedulerConfiguration(
            accountProfiles: [account],
            schedules: [schedule(profileID: account.id, meeting: meeting)]
        )
        let store = ScheduleStore(fileURL: url)
        XCTAssertTrue(store.save(configuration))
        XCTAssertEqual(ScheduleStore(fileURL: url).load().schedules.first?.meeting.passcode, "aBc123")
    }

    func testMeetingIDGrouping() {
        XCTAssertEqual(MeetingReference.groupedMeetingID("12345678901"), "123 4567 8901")
        XCTAssertEqual(MeetingReference.groupedMeetingID("1234567890"), "123 4567 890")
        XCTAssertEqual(MeetingReference.groupedMeetingID("123456"), "123456")
    }

    /// Pre-join preferences survive a save/load round trip.
    func testPreJoinSettingsPersist() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoom-auto-admit-prejoin-\(UUID().uuidString)")
            .appendingPathComponent("schedules.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let account = profile()
        var withPreferences = schedule(profileID: account.id)
        withPreferences.mutesMicrophoneBeforeJoining = false
        withPreferences.disablesCameraBeforeJoining = true

        let configuration = SchedulerConfiguration(
            accountProfiles: [account],
            schedules: [withPreferences]
        )
        let store = ScheduleStore(fileURL: url)
        XCTAssertTrue(store.save(configuration))

        let reloaded = ScheduleStore(fileURL: url).load()
        XCTAssertEqual(reloaded.schedules.first?.mutesMicrophoneBeforeJoining, false)
        XCTAssertEqual(reloaded.schedules.first?.disablesCameraBeforeJoining, true)
        XCTAssertEqual(reloaded, configuration)
    }
}
