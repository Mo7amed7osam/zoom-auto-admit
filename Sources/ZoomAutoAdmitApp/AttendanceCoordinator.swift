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
    private var panelOpenAttempted = false

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
            guard timer == nil else { return }

            self.group = group
            self.schedule = SchedulerDefaults.snapshotSchedule
            self.recorder = AttendanceSnapshotRecorder(group: group)
            self.coalescer.reset()
            self.panelOpenAttempted = false
            self.session = AttendanceSession(
                groupID: group.id,
                groupName: group.name,
                scheduleID: zoomSchedule.id,
                meetingName: zoomSchedule.meeting.name,
                startedAt: now,
                rosterSnapshot: group.students,
                evidenceSource: .accessibilitySnapshots
            )

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 3, repeating: Self.tickInterval, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()

            schedulerLog.write(
                "Attendance snapshots started for \(group.name) "
                + "(\(group.students.count) students, every \(Int(self.schedule.interval / 60)) min)"
            )
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
            guard let self, self.timer != nil, self.schedule.postAdmitEnabled else { return }
            let dueAt = self.coalescer.noteAdmit(at: now, delay: self.schedule.postAdmitDelay)
            self.logger.debug("Admit noted; post-admit snapshot due at \(dueAt)")
        }
    }

    /// Takes a snapshot immediately, for the menu command.
    func snapshotNow() {
        queue.async { [weak self] in
            guard let self, self.timer != nil else { return }
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
            takeSnapshotLocked(reason: .meetingStarted, at: now)
            persistLocked(finalizing: false, at: now)
            return
        }

        if coalescer.isPending, coalescer.isDue(at: now) {
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
        guard let recorder, let process = ZoomAXSupport.zoomApplication() else { return }

        // The list only exists while the panel is open. It is opened once, and
        // never toggled shut, so a user who opens it themselves is left alone.
        if !panelOpenAttempted {
            panelOpenAttempted = true
            openParticipantsPanel(pid: process.pid)
        }

        let readout = ZoomAXSupport.participantsReadout(pid: process.pid)
        if let snapshot = recorder.capture(readout, reason: reason, at: now) {
            schedulerLog.write(
                "Attendance snapshot (\(reason.rawValue)): \(snapshot.participants.count) participant(s), "
                + "reported=\(snapshot.reportedCount.map(String.init) ?? "n/a")"
            )
        } else {
            // A missed snapshot removes nobody: evidence only ever accumulates.
            schedulerLog.write("Attendance snapshot (\(reason.rawValue)) missed: participants list unavailable")
        }
    }

    private func openParticipantsPanel(pid: pid_t) {
        guard let reading = ZoomAXSupport.zoomMenuBarReading(pid: pid) else { return }
        let outcome = ZoomAXSupport.pressMenuItem(
            withIdentifier: ZoomAXSupport.showParticipantsMenuIdentifier,
            in: reading
        )
        schedulerLog.write("Attendance: opening participants panel — \(outcome)")
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

        if !store.save(reconciled) {
            logger.error("Could not write the attendance session to disk")
        }
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
