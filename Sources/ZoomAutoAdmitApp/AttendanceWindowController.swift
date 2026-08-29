import AppKit
import Foundation
import ZoomAutoAdmitCore

/// The attendance register: summary, per-student status, and the controls to
/// correct anything the app got wrong.
final class AttendanceWindowController: NSWindowController {
    private let store: AttendanceStore
    private let configurationProvider: () -> SchedulerConfiguration
    private let configurationWriter: (SchedulerConfiguration) -> Void
    private let liveSessionProvider: () -> AttendanceSession?
    private let finalizeHandler: () -> AttendanceSession?

    private var sessions: [AttendanceSession] = []
    private var selectedSession: AttendanceSession?

    private let sessionPopUp = NSPopUpButton()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let unmatchedLabel = NSTextField(wrappingLabelWithString: "")
    private let finalizeButton = NSButton(title: "Finalize Attendance", target: nil, action: nil)
    private let aiButton = NSButton(title: "Match with AI", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export CSV…", target: nil, action: nil)

    init(
        store: AttendanceStore,
        configurationProvider: @escaping () -> SchedulerConfiguration,
        configurationWriter: @escaping (SchedulerConfiguration) -> Void,
        liveSessionProvider: @escaping () -> AttendanceSession?,
        finalizeHandler: @escaping () -> AttendanceSession?
    ) {
        self.store = store
        self.configurationProvider = configurationProvider
        self.configurationWriter = configurationWriter
        self.liveSessionProvider = liveSessionProvider
        self.finalizeHandler = finalizeHandler

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Attendance"
        window.center()
        window.setFrameAutosaveName("AttendanceWindow")
        window.minSize = NSSize(width: 720, height: 540)
        super.init(window: window)
        window.contentView = makeContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func present() {
        reload()
        if let window, let screen = NSScreen.main, !screen.visibleFrame.intersects(window.frame) {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func makeContentView() -> NSView {
        sessionPopUp.target = self
        sessionPopUp.action = #selector(sessionChanged)

        summaryLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        finalizeButton.keyEquivalent = "\r"
        finalizeButton.bezelStyle = .rounded
        [aiButton, exportButton].forEach { $0.bezelStyle = .rounded }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("student"))
        column.title = "Students"
        column.width = 520
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 58
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.selectionHighlightStyle = .none
        table.style = .inset
        table.delegate = self
        table.dataSource = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        unmatchedLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        unmatchedLabel.textColor = .secondaryLabelColor

        finalizeButton.target = self
        finalizeButton.action = #selector(finalize)
        aiButton.target = self
        aiButton.action = #selector(matchWithAI)
        aiButton.toolTip = "Ask OpenRouter about the names local matching could not settle."
        exportButton.target = self
        exportButton.action = #selector(exportCSV)

        let actions = NSStackView(views: [aiButton, finalizeButton, NSView(), exportButton])
        actions.orientation = .horizontal
        actions.spacing = 10

        let header = NSStackView(views: [sessionPopUp, summaryLabel, statusLabel])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6

        let root = NSStackView(views: [header, scroll, unmatchedLabel, actions])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
            sessionPopUp.widthAnchor.constraint(equalToConstant: 420),
            unmatchedLabel.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            actions.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32)
        ])
        return container
    }

    // MARK: Data

    private func reload() {
        var all = store.loadAll()
        // A meeting in progress is not on disk as "the current one" yet.
        if let live = liveSessionProvider() {
            all.removeAll { $0.id == live.id }
            all.insert(live, at: 0)
        }
        sessions = all

        let previousID = selectedSession?.id
        sessionPopUp.removeAllItems()
        for session in sessions {
            sessionPopUp.addItem(withTitle: title(for: session))
        }
        if sessions.isEmpty {
            sessionPopUp.addItem(withTitle: "No attendance sessions yet")
        }

        if let previousID, let index = sessions.firstIndex(where: { $0.id == previousID }) {
            sessionPopUp.selectItem(at: index)
            selectedSession = sessions[index]
        } else {
            selectedSession = sessions.first
        }

        refresh()
    }

    private func refresh() {
        guard let session = selectedSession else {
            summaryLabel.stringValue = "No attendance yet"
            statusLabel.stringValue = "Link a schedule to a group, and attendance is recorded automatically."
            unmatchedLabel.stringValue = ""
            finalizeButton.isEnabled = false
            aiButton.isEnabled = false
            exportButton.isEnabled = false
            table.reloadData()
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        summaryLabel.stringValue = "\(session.groupName) · \(formatter.string(from: session.startedAt))"

        let notSeen = session.records.filter { $0.status == .notSeenYet }.count
        var parts = [
            "\(session.rosterSnapshot.count) students",
            "Present: \(session.presentCount)",
            "Needs Review: \(session.needsReviewCount)"
        ]
        parts.append(session.isFinalized ? "Absent: \(session.absentCount)" : "Not seen yet: \(notSeen)")
        statusLabel.stringValue = parts.joined(separator: "   ·   ")
            + (session.isFinalized ? "   ·   Finalized" : "   ·   In progress")

        var footer: [String] = []
        if !session.unmatchedZoomNames.isEmpty {
            footer.append("Unmatched Zoom names: " + session.unmatchedZoomNames.joined(separator: ", "))
        }
        if !session.snapshots.isEmpty {
            footer.append("Evidence: \(session.snapshots.count) snapshot(s)"
                + (session.missedSnapshotCount > 0 ? ", \(session.missedSnapshotCount) missed" : ""))
        }
        unmatchedLabel.stringValue = footer.joined(separator: "\n")

        finalizeButton.isEnabled = !session.isFinalized
        aiButton.isEnabled = APIKeyStore.hasKey
        aiButton.toolTip = APIKeyStore.hasKey
            ? "Ask OpenRouter about the names local matching could not settle."
            : "Add an OpenRouter API key in Settings to enable AI matching."
        exportButton.isEnabled = true

        table.reloadData()
    }

    private func title(for session: AttendanceSession) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let state = session.isFinalized ? "" : " — in progress"
        return "\(session.groupName) · \(formatter.string(from: session.startedAt))\(state)"
    }

    private func update(_ session: AttendanceSession) {
        selectedSession = session
        store.save(session)
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        }
        refresh()
    }

    // MARK: Actions

    @objc private func sessionChanged() {
        let index = sessionPopUp.indexOfSelectedItem
        guard sessions.indices.contains(index) else { return }
        selectedSession = sessions[index]
        refresh()
    }

    @objc private func finalizeAttendance() {
        guard let session = selectedSession else { return }

        let alert = NSAlert()
        alert.messageText = "Finalize attendance for \(session.groupName)?"
        alert.informativeText = "Students who were never seen will be marked Absent. The Zoom meeting is not ended."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Finalize")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        // A live session is finalized through the coordinator so recording stops
        // cleanly; a historical one is finalized in place.
        if let live = liveSessionProvider(), live.id == session.id, let finalized = finalizeHandler() {
            update(finalized)
        } else {
            update(AttendanceReconciler.reconcile(
                session: session,
                autoAcceptConfidence: autoAcceptConfidence(for: session),
                finalizing: true
            ))
        }
        reload()
    }

    @objc private func matchWithAI() {
        guard let session = selectedSession else { return }
        let (request, ids) = AIReconciliation.request(for: session)
        guard request.isWorthSending else {
            presentInfo("Nothing to match", detail: "Local matching already resolved everything it could.")
            return
        }

        aiButton.isEnabled = false
        aiButton.title = "Matching…"
        let threshold = autoAcceptConfidence(for: session)

        Task { [weak self] in
            let result = await OpenRouterClient().proposeMatches(for: request)
            await MainActor.run {
                guard let self else { return }
                self.aiButton.title = "Match with AI"
                self.aiButton.isEnabled = true

                switch result {
                case .success(let response):
                    let summary = AIReconciliation.apply(
                        response,
                        to: session,
                        ids: ids,
                        autoAcceptConfidence: threshold
                    )
                    self.update(summary.session)
                    var detail = "\(summary.appliedCount) matched, \(summary.reviewCount) need review."
                    if !summary.rejected.isEmpty {
                        detail += "\n\(summary.rejected.count) proposal(s) were rejected as unusable."
                    }
                    self.presentInfo("AI matching finished", detail: detail)

                case .failure(let error):
                    // Local results stand; nothing is lost.
                    self.presentInfo(
                        "AI matching unavailable",
                        detail: "\(error.message)\n\nThe attendance recorded locally is unchanged."
                    )
                }
            }
        }
    }

    @objc private func exportCSV() {
        guard let session = selectedSession else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "attendance-\(session.groupName).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try Data(AttendanceExport.csv(for: session).utf8).write(to: url)
        } catch {
            presentInfo("Could not export", detail: error.localizedDescription)
        }
    }

    private func autoAcceptConfidence(for session: AttendanceSession) -> Double {
        configurationProvider().studentGroups.first { $0.id == session.groupID }?.autoAcceptConfidence ?? 0.9
    }

    private func presentInfo(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

// MARK: - Rows

extension AttendanceWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        selectedSession?.records.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let session = selectedSession, session.records.indices.contains(row) else { return nil }
        let record = session.records[row]

        let marker = NSImageView()
        marker.image = NSImage(systemSymbolName: symbolName(for: record.status), accessibilityDescription: nil)
        marker.contentTintColor = color(for: record.status)
        marker.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        marker.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let name = NSTextField(labelWithString: record.studentName)
        name.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        var detailParts = [AttendanceExport.displayStatus(record.status)]
        if let zoomName = record.matchedZoomName {
            detailParts.append("Zoom: \(zoomName)")
        }
        if let confidence = record.confidence, record.matchSource != .manual {
            detailParts.append("\(Int(confidence * 100))%")
        }
        if record.matchSource != .none {
            detailParts.append(record.isManual ? "manual" : record.matchSource.rawValue)
        }
        // Snapshot evidence, phrased as evidence. Nothing here says the student
        // was present continuously between the first and last sighting.
        if let observation = record.matchedObservationID.flatMap({ session.observation(withID: $0) }),
           let first = observation.firstObservedAt,
           let last = observation.lastObservedAt {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            detailParts.append(
                "first observed \(formatter.string(from: first)) · "
                + "last observed \(formatter.string(from: last)) · "
                + "seen in \(observation.observationCount) snapshot\(observation.observationCount == 1 ? "" : "s")"
            )
        }

        let detail = NSTextField(labelWithString: detailParts.joined(separator: " · "))
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor

        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let matchButton = NSButton(title: "Match…", target: self, action: #selector(matchRow(_:)))
        matchButton.tag = row
        matchButton.isEnabled = !session.observations.isEmpty
        matchButton.controlSize = .small

        let absentButton = NSButton(title: "Absent", target: self, action: #selector(markAbsentRow(_:)))
        absentButton.tag = row
        absentButton.controlSize = .small

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearRow(_:)))
        clearButton.tag = row
        clearButton.isEnabled = record.isManual
        clearButton.controlSize = .small

        [matchButton, absentButton, clearButton].forEach { $0.bezelStyle = .rounded }

        let row = NSStackView(views: [marker, text, NSView(), matchButton, absentButton, clearButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        return row
    }

    private func symbolName(for status: AttendanceStatus) -> String {
        switch status {
        case .present: return "checkmark.circle.fill"
        case .absent: return "xmark.circle.fill"
        case .needsReview: return "exclamationmark.triangle.fill"
        case .notSeenYet: return "clock"
        }
    }

    private func color(for status: AttendanceStatus) -> NSColor {
        switch status {
        case .present: return .systemGreen
        case .absent: return .systemRed
        case .needsReview: return .systemOrange
        case .notSeenYet: return .secondaryLabelColor
        }
    }

    /// Manual matching, plus the offer to remember the name for next time.
    @objc private func matchRow(_ sender: NSButton) {
        guard let session = selectedSession, session.records.indices.contains(sender.tag) else { return }
        let record = session.records[sender.tag]

        let alert = NSAlert()
        alert.messageText = "Match \(record.studentName)"
        alert.informativeText = "Choose the Zoom name this student used."

        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 25))
        for observation in session.observations {
            popUp.addItem(withTitle: observation.rawName)
        }
        guard !session.observations.isEmpty else { return }

        let remember = NSButton(checkboxWithTitle: "Remember this name for future meetings", target: nil, action: nil)
        remember.state = .on
        remember.frame = NSRect(x: 0, y: 0, width: 320, height: 20)

        let accessory = NSStackView(views: [popUp, remember])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 320, height: 56)
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Match")

        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let observation = session.observations[popUp.indexOfSelectedItem]

        update(AttendanceReconciler.applyManualMatch(
            session: session,
            studentID: record.studentID,
            observationID: observation.id,
            status: .present
        ))

        if remember.state == .on {
            learnAlias(observation.rawName, studentID: record.studentID, groupID: session.groupID)
        }
    }

    /// Learned aliases are what make the next meeting resolve without AI.
    private func learnAlias(_ alias: String, studentID: UUID, groupID: UUID) {
        var configuration = configurationProvider()
        guard let index = configuration.studentGroups.firstIndex(where: { $0.id == groupID }) else { return }

        switch AliasLearning.learn(alias: alias, forStudent: studentID, in: configuration.studentGroups[index]) {
        case .success(let updated):
            configuration.studentGroups[index] = updated
            configurationWriter(configuration)
        case .failure(let error):
            presentInfo("Couldn't remember that name", detail: error.message)
        }
    }

    @objc private func markAbsentRow(_ sender: NSButton) {
        guard let session = selectedSession, session.records.indices.contains(sender.tag) else { return }
        update(AttendanceReconciler.applyManualMatch(
            session: session,
            studentID: session.records[sender.tag].studentID,
            observationID: nil,
            status: .absent
        ))
    }

    @objc private func clearRow(_ sender: NSButton) {
        guard let session = selectedSession, session.records.indices.contains(sender.tag) else { return }
        let cleared = AttendanceReconciler.clearMatch(
            session: session,
            studentID: session.records[sender.tag].studentID
        )
        update(AttendanceReconciler.reconcile(
            session: cleared,
            autoAcceptConfidence: autoAcceptConfidence(for: session),
            finalizing: cleared.isFinalized
        ))
    }
}
