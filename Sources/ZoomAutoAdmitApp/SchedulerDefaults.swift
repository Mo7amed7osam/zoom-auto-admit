import Foundation

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

    static var enablesAutoAdmit: Bool {
        get { defaults.object(forKey: autoAdmitKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: autoAdmitKey) }
    }
}
