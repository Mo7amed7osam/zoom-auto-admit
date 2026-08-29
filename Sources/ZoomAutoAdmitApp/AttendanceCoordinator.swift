import AppKit
import Foundation
import OSLog
import ZoomAXSupport
import ZoomAutoAdmitCore

/// Takes periodic attendance snapshots alongside a live meeting.
///
/// Deliberately isolated from Auto Admit: it owns its own timer and its own
/// failures. A snapshot that cannot be taken is logged and counted, and the
/// next one runs normally — admissions, the scheduler and the meeting workflow
/// never depend on any of it.
final class AttendanceCoordinator {
    /// How often the timer wakes to *decide*. Snapshots themselves are governed
    /// by `SnapshotSchedule`, which is minutes apart.
    private static let tickInterval: TimeInterval = 5

    private let logger = Logger(subsystem: "com.mohamedhosam.ZoomAutoAdmit", category: "attendance")
    private let store: AttendanceStore
    private let schedulerLog: SchedulerLog
    private let queue = DispatchQueue(label: "com.mohamedhosam.ZoomAutoAdmit.attendance", qos: .utility)

    private var timer: DispatchSourceTimer?
    private var recorder: AttendanceSnapshotRecorder?
    private var session: AttendanceSession?
    private var group: StudentGroup?
    private var coalescer = PostAdmitCoalescer()
    private var schedule = SnapshotSchedule()

    private(set) var liveSummary: AttendanceLiveSummary?
    var onChange: (() -> Void)?

    init(store: AttendanceStore = AttendanceStore(), schedulerLog: SchedulerLog = .shared) {
        self.store = store
        self.schedulerLog = schedulerLog
    }

    var isRecording: Bool { queue.sync { timer != nil } }
    var currentSession: AttendanceSession? { queue.sync { session } }

    /// Begins snapshotting for a verified meeting.
    func start(group: StudentGroup, schedule zoomSchedule: ZoomSchedule, at now: Date = Date()) {
        queue.sync {
            guard timer == nil else {
                schedulerLog.write(
                    "[attendance] start-ignored reason=session-already-active "
                    + "session=\(session?.id.uuidString ?? "unknown")"
                )
                return
            }

            self.group = group
            self.schedule = SchedulerDefaults.snapshotSchedule
            self.recorder = AttendanceSnapshotRecorder(group: group)
            self.coalescer.reset()
            self.session = AttendanceSession(
                groupID: group.id,
                groupName: group.name,
                scheduleID: zoomSchedule.id,
                meetingName: zoomSchedule.meeting.name,
                startedAt: now,
                rosterSnapshot: group.students,
                evidenceSource: .accessibilitySnapshots
            )

            guard let createdSession = self.session else { return }
            schedulerLog.write(
                "[attendance] session-created id=\(createdSession.id.uuidString) "
                + "schedule=\(zoomSchedule.id.uuidString) group=\(group.id.uuidString) "
                + "roster=\(createdSession.rosterSnapshot.count) recorder-started=yes"
            )
            schedulerLog.write(
                "[attendance] snapshot-state meeting_started=due "
                + "nextPeriodicAt=after-first-success tickInterval=\(Int(Self.tickInterval))s"
            )

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 3, repeating: Self.tickInterval, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()

            // Persist the empty evidence session immediately. This proves the
            // lifecycle is wired even if Zoom's first participant read fails.
            persistLocked(finalizing: false, at: now)
        }
    }

    func stop(at now: Date = Date()) {
        queue.sync {
            guard let timer else { return }
            timer.setEventHandler {}
            timer.cancel()
            self.timer = nil
            persistLocked(finalizing: false, at: now)
            schedulerLog.write("Attendance snapshots stopped")
        }
    }

    /// Takes a final snapshot and closes the register.
    @discardableResult
    func finalize(at now: Date = Date()) -> AttendanceSession? {
        queue.sync {
            if let timer {
                timer.setEventHandler {}
                timer.cancel()
                self.timer = nil
            }
            takeSnapshotLocked(reason: .final, at: now)
            guard let finalized = persistLocked(finalizing: true, at: now) else { return nil }
            schedulerLog.write(
                "Attendance finalized for \(finalized.groupName): "
                + "present=\(finalized.presentCount) absent=\(finalized.absentCount) "
                + "review=\(finalized.needsReviewCount) snapshots=\(finalized.snapshots.count) "
                + "missed=\(finalized.missedSnapshotCount)"
            )
            return finalized
        }
    }

    /// Called when Auto Admit lets somebody in. Bursts coalesce into one snapshot.
    func noteAdmit(at now: Date = Date()) {
        queue.async { [weak self] in
            guard let self else { return }
            self.schedulerLog.write("[attendance] admit-observed at=\(Self.iso8601(now))")
            guard self.timer != nil, self.schedule.postAdmitEnabled else {
                self.schedulerLog.write("[attendance] post-admit-snapshot skipped=no-active-session")
                return
            }
            let dueAt = self.coalescer.noteAdmit(at: now, delay: self.schedule.postAdmitDelay)
            self.schedulerLog.write(
                "[attendance] post-admit-snapshot scheduled=\(Self.iso8601(dueAt)) "
                + "burst=\(self.coalescer.admitsInBurst)"
            )
        }
    }

    /// Takes a snapshot immediately, for the menu command.
    func snapshotNow() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.timer != nil else {
                self.schedulerLog.write("[attendance] snapshot-request reason=manual rejected=no-active-session")
                return
            }
            self.takeSnapshotLocked(reason: .manual, at: Date())
            self.persistLocked(finalizing: false, at: Date())
        }
    }

    // MARK: Timer

    private func tick() {
        guard let recorder, session != nil else { return }
        let now = Date()

        // The very first snapshot happens as soon as the meeting is verified.
        if recorder.snapshots.isEmpty {
            schedulerLog.write("[attendance] meeting_started snapshot firing")
            takeSnapshotLocked(reason: .meetingStarted, at: now)
            persistLocked(finalizing: false, at: now)
            return
        }

        if coalescer.isPending, coalescer.isDue(at: now) {
            schedulerLog.write("[attendance] post-admit snapshot firing")
            coalescer.reset()
            takeSnapshotLocked(reason: .postAdmit, at: now)
            persistLocked(finalizing: false, at: now)
            return
        }

        if schedule.isPeriodicDue(now: now, lastSnapshotAt: recorder.lastSnapshotAt) {
            takeSnapshotLocked(reason: .periodic, at: now)
            persistLocked(finalizing: false, at: now)
        }
    }

    private func takeSnapshotLocked(reason: SnapshotReason, at now: Date) {
        schedulerLog.write(
            "[attendance] snapshot-request reason=\(reason.rawValue) at=\(Self.iso8601(now))"
        )
        guard let recorder else {
            schedulerLog.write("[attendance] snapshot-failed reason=recorder-not-started")
            return
        }
        guard let process = ZoomAXSupport.zoomApplication() else {
            schedulerLog.write("[attendance] snapshot-failed reason=zoom-not-running")
            return
        }

        var diagnostics = ZoomAXSupport.participantsReadoutDiagnostics(pid: process.pid)
        var panelState: ZoomAXSupport.ParticipantsPanelState = diagnostics.readout.listAvailable ? .open : .unknown

        if !diagnostics.readout.listAvailable {
            let reading = ZoomAXSupport.participantsReading(pid: process.pid)
            panelState = reading.state
            schedulerLog.write("[attendance] participants-panel state=\(reading.state.rawValue)")
            if reading.state != .open {
                let outcome = openParticipantsPanel(reading: reading)
                schedulerLog.write("[attendance] participants-panel open-outcome=\(outcome)")
            }

            // Whether the panel was opened or Zoom merely returned a transient
            // partial tree, discard every old AX reference and retry once.
            Thread.sleep(forTimeInterval: 0.4)
            diagnostics = ZoomAXSupport.participantsReadoutDiagnostics(pid: process.pid)
            if diagnostics.readout.listAvailable { panelState = .open }
        }

        let readout = diagnostics.readout
        schedulerLog.write(
            "[attendance] zoom-pid=\(process.pid) windows=\(diagnostics.windowsCount) "
            + "windowsError=\(diagnostics.windowsError.diagnosticDescription) panel=\(panelState.rawValue)"
        )
        let rawPanelists = readout.admitted.map { row in
            "\(row.rawText){roles=\(row.roles.map(\.rawValue).sorted().joined(separator: ","))}"
        }.joined(separator: " | ")
        schedulerLog.write(
            "[attendance] parser available=\(readout.listAvailable) "
            + "reported=\(readout.reportedCount.map(String.init) ?? "n/a") "
            + "panelists=[\(rawPanelists)] waiting=\(readout.waiting.count)"
        )

        if let snapshot = recorder.capture(readout, reason: reason, at: now) {
            schedulerLog.write(
                "[attendance] filtered=[\(snapshot.participants.map(\.rawZoomName).joined(separator: " | "))]"
            )
            schedulerLog.write(
                "[attendance] snapshot-captured id=\(snapshot.id.uuidString) "
                + "reason=\(reason.rawValue) participants=\(snapshot.participants.count) "
                + "union=\(recorder.observedIdentityCount)"
            )
        } else {
            // A missed snapshot removes nobody: evidence only ever accumulates.
            schedulerLog.write(
                "[attendance] snapshot-missed reason=\(reason.rawValue) "
                + "missed=\(recorder.missedSnapshots) union=\(recorder.observedIdentityCount)"
            )
        }
    }

    private func openParticipantsPanel(reading: ZoomAXSupport.ParticipantsReading) -> String {
        switch reading.state {
        case .open:
            return "already-open"
        case .closed:
            if let command = reading.menuCommand {
                return String(describing: ZoomAXSupport.pressParticipantsMenuCommand(command, in: reading))
            }
            if let toggle = reading.toggle {
                return String(describing: ZoomAXSupport.pressParticipantsToggle(toggle, in: reading))
            }
            return "control-unavailable"
        case .unknown:
            return "state-unknown-refused-toggle"
        }
    }

    @discardableResult
    private func persistLocked(finalizing: Bool, at now: Date) -> AttendanceSession? {
        guard var current = session, let recorder, let group else { return nil }

        current.observations = recorder.observations
        current.snapshots = recorder.snapshots
        current.missedSnapshotCount = recorder.missedSnapshots
        if finalizing { current.endedAt = now }

        let reconciled = AttendanceReconciler.reconcile(
            session: current,
            autoAcceptConfidence: group.autoAcceptConfidence,
            finalizing: finalizing,
            at: now
        )
        session = reconciled

        let saved = store.save(reconciled)
        if !saved {
            logger.error("Could not write the attendance session to disk")
        }
        let matched = reconciled.records.filter { $0.status == .present }.count
        schedulerLog.write(
            "[attendance] reconcile matched=\(matched) "
            + "unresolved=\(reconciled.unmatchedZoomNames.count) review=\(reconciled.needsReviewCount)"
        )
        schedulerLog.write(
            "[attendance] session-saved=\(saved) id=\(reconciled.id.uuidString) "
            + "snapshots=\(reconciled.snapshots.count) union=\(reconciled.observations.count)"
        )
        let next = recorder.lastSnapshotAt.flatMap(schedule.nextPeriodicDate(after:))
        schedulerLog.write("[attendance] next-snapshot=\(next.map(Self.iso8601) ?? "meeting_started pending")")
        publishSummaryLocked(reconciled, recorder: recorder)
        return reconciled
    }

    private func publishSummaryLocked(_ session: AttendanceSession, recorder: AttendanceSnapshotRecorder) {
        let summary = AttendanceLiveSummary(
            groupName: session.groupName,
            observedIdentities: recorder.observedIdentityCount,
            matchedStudents: session.records.filter { $0.status == .present }.count,
            totalStudents: session.rosterSnapshot.count,
            lastSnapshotAt: recorder.lastSnapshotAt,
            nextSnapshotAt: recorder.lastSnapshotAt.flatMap(schedule.nextPeriodicDate(after:)),
            missedSnapshots: recorder.missedSnapshots
        )
        DispatchQueue.main.async { [weak self] in
            self?.liveSummary = summary
            self?.onChange?()
        }
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// What the menu shows while a class is running. Phrased as evidence, not as
/// live presence: nothing here claims anybody is in the meeting right now.
struct AttendanceLiveSummary {
    let groupName: String
    let observedIdentities: Int
    let matchedStudents: Int
    let totalStudents: Int
    let lastSnapshotAt: Date?
    let nextSnapshotAt: Date?
    let missedSnapshots: Int

    var lines: [String] {
        var result = [
            "Observed identities: \(observedIdentities)",
            "Matched students: \(matchedStudents) / \(totalStudents)"
        ]
        if let lastSnapshotAt {
            result.append("Last snapshot: \(Self.formatter.string(from: lastSnapshotAt))")
        }
        if let nextSnapshotAt {
            result.append("Next snapshot: \(Self.formatter.string(from: nextSnapshotAt))")
        }
        if missedSnapshots > 0 {
            result.append("Missed snapshots: \(missedSnapshots)")
        }
        return result
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
