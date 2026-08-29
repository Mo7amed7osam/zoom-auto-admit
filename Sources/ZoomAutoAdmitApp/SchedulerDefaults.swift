import Foundation
import ZoomAutoAdmitCore

/// Defaults applied to newly created schedules, editable in Settings.
enum SchedulerDefaults {
    private static let microphoneKey = "defaultMutesMicrophone"
    private static let cameraKey = "defaultDisablesCamera"
    private static let autoAdmitKey = "defaultEnablesAutoAdmit"

    private static let defaults = UserDefaults.standard

    static var mutesMicrophone: Bool {
        get { defaults.object(forKey: microphoneKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: microphoneKey) }
    }

    static var disablesCamera: Bool {
        get { defaults.object(forKey: cameraKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: cameraKey) }
    }

    /// Model used for AI attendance matching.
    static var aiModel: String {
        get { defaults.string(forKey: "aiModel") ?? "openai/gpt-4o-mini" }
        set { defaults.set(newValue, forKey: "aiModel") }
    }

    /// Attendance snapshot timing, bounded by `SnapshotSchedule`.
    static var snapshotSchedule: SnapshotSchedule {
        get {
            SnapshotSchedule(
                periodicEnabled: defaults.object(forKey: "snapshotPeriodicEnabled") as? Bool ?? true,
                interval: defaults.object(forKey: "snapshotInterval") as? Double
                    ?? SnapshotSchedule.defaultInterval,
                postAdmitEnabled: defaults.object(forKey: "snapshotPostAdmitEnabled") as? Bool ?? true,
                postAdmitDelay: defaults.object(forKey: "snapshotPostAdmitDelay") as? Double
                    ?? SnapshotSchedule.defaultPostAdmitDelay
            )
        }
        set {
            defaults.set(newValue.periodicEnabled, forKey: "snapshotPeriodicEnabled")
            defaults.set(newValue.interval, forKey: "snapshotInterval")
            defaults.set(newValue.postAdmitEnabled, forKey: "snapshotPostAdmitEnabled")
            defaults.set(newValue.postAdmitDelay, forKey: "snapshotPostAdmitDelay")
        }
    }

    static var enablesAutoAdmit: Bool {
        get { defaults.object(forKey: autoAdmitKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: autoAdmitKey) }
    }
}
