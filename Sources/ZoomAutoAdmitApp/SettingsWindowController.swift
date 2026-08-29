import AppKit
import ServiceManagement
import ZoomAXSupport
import ZoomAutoAdmitCore

/// Settings, including the diagnostic tools that used to sit in the main menu.
///
/// Everyday use never needs this window; it exists so the menu can stay short.
final class SettingsWindowController: NSWindowController {
    var onOpenAccessibilitySettings: (() -> Void)?
    var onCheckAccessibility: (() -> Void)?
    var onCaptureZoomUI: (() -> Void)?
    var onOpenAccessibilityLog: (() -> Void)?
    var onOpenSchedulerLog: (() -> Void)?

    private let accessibilityStatusLabel = NSTextField(labelWithString: "")
    private let periodicSnapshotButton = NSButton(
        checkboxWithTitle: "Periodic participant snapshots",
        target: nil,
        action: nil
    )
    private let snapshotIntervalField = NSTextField()
    private let postAdmitSnapshotButton = NSButton(
        checkboxWithTitle: "Snapshot after Auto Admit",
        target: nil,
        action: nil
    )
    private let postAdmitDelayField = NSTextField()
    private let aiKeyField = NSSecureTextField()
    private let aiKeyStatusLabel = NSTextField(labelWithString: "")
    private let aiModelField = NSTextField()
    private lazy var saveKeyButton = NSButton(title: "Save Key", target: self, action: #selector(saveAPIKey))
    private lazy var clearKeyButton = NSButton(title: "Remove Key", target: self, action: #selector(clearAPIKey))
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Launch at Login", target: nil, action: nil)
    private let microphoneDefaultButton = NSButton(
        checkboxWithTitle: "Mute microphone before joining",
        target: nil,
        action: nil
    )
    private let cameraDefaultButton = NSButton(
        checkboxWithTitle: "Turn camera off before joining",
        target: nil,
        action: nil
    )
    private let autoAdmitDefaultButton = NSButton(
        checkboxWithTitle: "Enable Auto Admit after the meeting starts",
        target: nil,
        action: nil
    )

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Zoom Auto Admit Settings"
        window.center()
        super.init(window: window)
        window.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func present() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        let trusted = ZoomAXSupport.accessibilityTrustSnapshot(prompt: false).isUsableWithoutRelaunch
        accessibilityStatusLabel.stringValue = trusted
            ? "✓ Accessibility ready"
            : "Accessibility permission required"
        accessibilityStatusLabel.textColor = trusted ? .systemGreen : .systemRed

        launchAtLoginButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
        aiKeyField.placeholderString = "sk-or-…"
        aiKeyField.stringValue = ""
        aiKeyStatusLabel.stringValue = APIKeyStore.hasKey
            ? "Key stored: \(APIKeyStore.redacted(APIKeyStore.load()))"
            : "No key stored — AI matching is off."
        aiKeyStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        aiKeyStatusLabel.textColor = .secondaryLabelColor
        aiModelField.stringValue = SchedulerDefaults.aiModel
        aiModelField.placeholderString = "openai/gpt-4o-mini"
        clearKeyButton.isEnabled = APIKeyStore.hasKey

        let snapshots = SchedulerDefaults.snapshotSchedule
        periodicSnapshotButton.state = snapshots.periodicEnabled ? .on : .off
        snapshotIntervalField.stringValue = String(Int(snapshots.interval / 60))
        postAdmitSnapshotButton.state = snapshots.postAdmitEnabled ? .on : .off
        postAdmitDelayField.stringValue = String(Int(snapshots.postAdmitDelay))

        microphoneDefaultButton.state = SchedulerDefaults.mutesMicrophone ? .on : .off
        cameraDefaultButton.state = SchedulerDefaults.disablesCamera ? .on : .off
        autoAdmitDefaultButton.state = SchedulerDefaults.enablesAutoAdmit ? .on : .off
    }

    private func makeContentView() -> NSView {
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(toggleLaunchAtLogin)
        for control in [periodicSnapshotButton, postAdmitSnapshotButton] {
            control.target = self
            control.action = #selector(snapshotSettingsChanged)
        }
        for field in [snapshotIntervalField, postAdmitDelayField] {
            field.target = self
            field.action = #selector(snapshotSettingsChanged)
            field.widthAnchor.constraint(equalToConstant: 60).isActive = true
        }

        microphoneDefaultButton.target = self
        microphoneDefaultButton.action = #selector(toggleDefaults)
        cameraDefaultButton.target = self
        cameraDefaultButton.action = #selector(toggleDefaults)
        autoAdmitDefaultButton.target = self
        autoAdmitDefaultButton.action = #selector(toggleDefaults)

        let openSettingsButton = NSButton(
            title: "Open System Settings",
            target: self,
            action: #selector(openAccessibilitySettings)
        )
        let checkButton = NSButton(title: "Check Again", target: self, action: #selector(checkAccessibility))

        let stack = NSStackView(views: [
            section("Accessibility", views: [
                accessibilityStatusLabel,
                caption("Zoom Auto Admit needs Accessibility access to read and press Zoom controls."),
                row([openSettingsButton, checkButton])
            ]),
            section("General", views: [launchAtLoginButton]),
            section("New schedules use these defaults", views: [
                microphoneDefaultButton,
                cameraDefaultButton,
                autoAdmitDefaultButton
            ]),
            section("Attendance backup", views: [
                periodicSnapshotButton,
                row([NSTextField(labelWithString: "Interval"), snapshotIntervalField,
                     NSTextField(labelWithString: "minutes")]),
                postAdmitSnapshotButton,
                row([NSTextField(labelWithString: "Post-admit delay"), postAdmitDelayField,
                     NSTextField(labelWithString: "seconds")]),
                caption("""
                Snapshots record which Zoom identities were visible at that moment. \
                They are evidence of attendance, not a live presence tracker.
                """)
            ]),
            section("AI attendance matching", views: [
                aiKeyField,
                aiKeyStatusLabel,
                row([saveKeyButton, clearKeyButton]),
                aiModelField,
                caption("""
                Used only for student names local matching cannot settle. \
                The key is stored in your macOS Keychain, never in a file and never in a log.
                """)
            ]),
            section("Advanced", views: [
                row([
                    NSButton(title: "Scheduler Log", target: self, action: #selector(openSchedulerLog)),
                    NSButton(title: "Accessibility Log", target: self, action: #selector(openAccessibilityLog)),
                    NSButton(title: "Capture Zoom UI", target: self, action: #selector(captureZoomUI))
                ]),
                caption("Cross-Space fallback: Off. Zoom is never moved between Desktops automatically.")
            ])
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20)
        ])
        return container
    }

    private func section(_ title: String, views: [NSView]) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        heading.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [heading] + views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.preferredMaxLayoutWidth = 440
        return field
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            presentError("Launch at Login couldn't be changed", detail: error.localizedDescription)
        }
        refresh()
    }

    /// Values are clamped by `SnapshotSchedule`, so a typo cannot turn the
    /// snapshot system into a poll.
    @objc private func snapshotSettingsChanged() {
        SchedulerDefaults.snapshotSchedule = SnapshotSchedule(
            periodicEnabled: periodicSnapshotButton.state == .on,
            interval: (Double(snapshotIntervalField.stringValue) ?? 15) * 60,
            postAdmitEnabled: postAdmitSnapshotButton.state == .on,
            postAdmitDelay: Double(postAdmitDelayField.stringValue) ?? 8
        )
        refresh()
    }

    @objc private func toggleDefaults() {
        SchedulerDefaults.mutesMicrophone = microphoneDefaultButton.state == .on
        SchedulerDefaults.disablesCamera = cameraDefaultButton.state == .on
        SchedulerDefaults.enablesAutoAdmit = autoAdmitDefaultButton.state == .on
    }

    @objc private func saveAPIKey() {
        let key = aiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if APIKeyStore.save(key) {
            // Cleared immediately so the key is not left sitting in a view.
            aiKeyField.stringValue = ""
            SchedulerDefaults.aiModel = aiModelField.stringValue
        } else {
            presentError("Couldn't save the key", detail: "The macOS Keychain refused the item.")
        }
        refresh()
    }

    @objc private func clearAPIKey() {
        APIKeyStore.delete()
        refresh()
    }

    @objc private func openAccessibilitySettings() { onOpenAccessibilitySettings?() }
    @objc private func checkAccessibility() {
        onCheckAccessibility?()
        refresh()
    }
    @objc private func captureZoomUI() { onCaptureZoomUI?() }
    @objc private func openAccessibilityLog() { onOpenAccessibilityLog?() }
    @objc private func openSchedulerLog() { onOpenSchedulerLog?() }

    private func presentError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
