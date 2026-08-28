import AppKit
import Foundation
import ZoomAutoAdmitCore

/// Editor for schedules and account profiles.
///
/// Built programmatically so the app stays a single binary with no nib
/// resources. The window is only ever shown when the user asks for it; the
/// scheduler itself never needs any UI to run.
final class SchedulerWindowController: NSWindowController {
    private let coordinator: SchedulerCoordinator
    private var configuration: SchedulerConfiguration

    private let scheduleTable = NSTableView()
    private let profileTable = NSTableView()

    // Schedule fields
    private let nameField = NSTextField()
    private let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let recurrencePopUp = NSPopUpButton()
    private let weekdayButtons: [NSButton] = Weekday.allCases.map {
        NSButton(checkboxWithTitle: $0.shortName, target: nil, action: nil)
    }
    private let oneTimeDatePicker = NSDatePicker()
    private let startTimePicker = NSDatePicker()
    private let usesEndTimeButton = NSButton(checkboxWithTitle: "Stop Auto Admit at", target: nil, action: nil)
    private let endTimePicker = NSDatePicker()
    private let accountPopUp = NSPopUpButton()
    private let meetingKindPopUp = NSPopUpButton()
    private let meetingNameField = NSTextField()
    private let meetingIDField = NSTextField()
    private let autoAdmitButton = NSButton(checkboxWithTitle: "Enable Auto Admit", target: nil, action: nil)
    private let launchEarlyField = NSTextField()

    // Profile fields
    private let profileNameField = NSTextField()
    private let profileIdentifierField = NSTextField()
    private let detectedAccountsPopUp = NSPopUpButton()

    private var selectedScheduleIndex: Int? {
        scheduleTable.selectedRow >= 0 ? scheduleTable.selectedRow : nil
    }

    private var selectedProfileIndex: Int? {
        profileTable.selectedRow >= 0 ? profileTable.selectedRow : nil
    }

    init(coordinator: SchedulerCoordinator) {
        self.coordinator = coordinator
        self.configuration = coordinator.currentConfiguration

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Zoom Auto Admit Schedules"
        window.center()
        super.init(window: window)
        window.contentView = makeContentView()
        reloadFromConfiguration()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func present() {
        configuration = coordinator.currentConfiguration
        reloadFromConfiguration()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func makeContentView() -> NSView {
        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let schedulesItem = NSTabViewItem(identifier: "schedules")
        schedulesItem.label = "Schedules"
        schedulesItem.view = makeSchedulesTab()
        tabView.addTabViewItem(schedulesItem)

        let profilesItem = NSTabViewItem(identifier: "profiles")
        profilesItem.label = "Account Profiles"
        profilesItem.view = makeProfilesTab()
        tabView.addTabViewItem(profilesItem)

        let container = NSView()
        container.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            tabView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            tabView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return container
    }

    private func makeSchedulesTab() -> NSView {
        let view = NSView()

        configure(table: scheduleTable, columnTitle: "Schedule")
        scheduleTable.delegate = self
        scheduleTable.dataSource = self
        let scroll = scrollView(for: scheduleTable)

        let addButton = NSButton(title: "+", target: self, action: #selector(addSchedule))
        let removeButton = NSButton(title: "−", target: self, action: #selector(removeSchedule))
        let runNowButton = NSButton(title: "Run Now", target: self, action: #selector(runSelectedScheduleNow))
        runNowButton.toolTip = "Run this schedule immediately, exactly as the scheduler would."
        let listButtons = NSStackView(views: [addButton, removeButton, runNowButton])
        listButtons.orientation = .horizontal
        listButtons.spacing = 6

        recurrencePopUp.addItems(withTitles: ["One time", "Every day", "Selected weekdays"])
        recurrencePopUp.target = self
        recurrencePopUp.action = #selector(recurrenceChanged)

        meetingKindPopUp.addItems(withTitles: ["Meeting ID", "Personal meeting (Zoom menu)"])
        meetingKindPopUp.target = self
        meetingKindPopUp.action = #selector(meetingKindChanged)

        configure(datePicker: oneTimeDatePicker, elements: .yearMonthDay)
        configure(datePicker: startTimePicker, elements: .hourMinute)
        configure(datePicker: endTimePicker, elements: .hourMinute)

        meetingIDField.placeholderString = "123 4567 8901"
        launchEarlyField.placeholderString = "2"
        launchEarlyField.formatter = integerFormatter()

        let weekdayRow = NSStackView(views: weekdayButtons)
        weekdayRow.orientation = .horizontal
        weekdayRow.spacing = 4

        let endTimeRow = NSStackView(views: [usesEndTimeButton, endTimePicker])
        endTimeRow.orientation = .horizontal
        endTimeRow.spacing = 8

        let form = NSGridView(views: [
            [label("Name"), nameField],
            [NSView(), enabledButton],
            [label("Repeats"), recurrencePopUp],
            [label("Weekdays"), weekdayRow],
            [label("Date"), oneTimeDatePicker],
            [label("Start time"), startTimePicker],
            [label("End time"), endTimeRow],
            [label("Account"), accountPopUp],
            [label("Meeting type"), meetingKindPopUp],
            [label("Meeting name"), meetingNameField],
            [label("Meeting ID"), meetingIDField],
            [NSView(), autoAdmitButton],
            [label("Launch Zoom early (min)"), launchEarlyField]
        ])
        form.translatesAutoresizingMaskIntoConstraints = false
        form.rowSpacing = 8
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSchedules))
        saveButton.keyEquivalent = "\r"
        let revertButton = NSButton(title: "Revert", target: self, action: #selector(revert))
        let actionRow = NSStackView(views: [revertButton, saveButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 8

        [scroll, listButtons, form, actionRow].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            scroll.widthAnchor.constraint(equalToConstant: 220),
            scroll.bottomAnchor.constraint(equalTo: listButtons.topAnchor, constant: -6),

            listButtons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            listButtons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            form.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 16),
            form.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            form.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),

            actionRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            actionRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            nameField.widthAnchor.constraint(equalToConstant: 320),
            meetingNameField.widthAnchor.constraint(equalToConstant: 320),
            meetingIDField.widthAnchor.constraint(equalToConstant: 200),
            launchEarlyField.widthAnchor.constraint(equalToConstant: 80),
            accountPopUp.widthAnchor.constraint(equalToConstant: 320)
        ])
        return view
    }

    private func makeProfilesTab() -> NSView {
        let view = NSView()

        configure(table: profileTable, columnTitle: "Account Profile")
        profileTable.delegate = self
        profileTable.dataSource = self
        let scroll = scrollView(for: profileTable)

        let addButton = NSButton(title: "+", target: self, action: #selector(addProfile))
        let removeButton = NSButton(title: "−", target: self, action: #selector(removeProfile))
        let listButtons = NSStackView(views: [addButton, removeButton])
        listButtons.orientation = .horizontal
        listButtons.spacing = 6

        profileIdentifierField.placeholderString = "name@example.com"
        detectedAccountsPopUp.target = self
        detectedAccountsPopUp.action = #selector(useDetectedAccount)

        let detectButton = NSButton(
            title: "Read accounts from Zoom",
            target: self,
            action: #selector(detectAccounts)
        )
        detectButton.toolTip = "Reads the saved accounts from Zoom's Switch account menu."

        let explanation = NSTextField(wrappingLabelWithString: """
        A profile only identifies an account that is already signed in to Zoom. \
        No password or token is stored. Use the email address: several saved \
        accounts can share the same display name.
        """)
        explanation.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: 11)

        let form = NSGridView(views: [
            [label("Profile name"), profileNameField],
            [label("Zoom account"), profileIdentifierField],
            [label("Detected"), detectedAccountsPopUp],
            [NSView(), detectButton],
            [NSView(), explanation]
        ])
        form.translatesAutoresizingMaskIntoConstraints = false
        form.rowSpacing = 8
        form.columnSpacing = 10
        form.column(at: 0).xPlacement = .trailing

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSchedules))
        let actionRow = NSStackView(views: [saveButton])
        actionRow.orientation = .horizontal

        [scroll, listButtons, form, actionRow].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            scroll.widthAnchor.constraint(equalToConstant: 220),
            scroll.bottomAnchor.constraint(equalTo: listButtons.topAnchor, constant: -6),

            listButtons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            listButtons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            form.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 16),
            form.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            form.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8),

            actionRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            actionRow.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),

            profileNameField.widthAnchor.constraint(equalToConstant: 320),
            profileIdentifierField.widthAnchor.constraint(equalToConstant: 320),
            detectedAccountsPopUp.widthAnchor.constraint(equalToConstant: 320),
            explanation.widthAnchor.constraint(equalToConstant: 380)
        ])
        return view
    }

    // MARK: Binding

    private func reloadFromConfiguration() {
        accountPopUp.removeAllItems()
        for profile in configuration.accountProfiles {
            accountPopUp.addItem(withTitle: "\(profile.name) — \(profile.accountIdentifier)")
        }
        if configuration.accountProfiles.isEmpty {
            accountPopUp.addItem(withTitle: "No account profiles yet")
        }
        scheduleTable.reloadData()
        profileTable.reloadData()
        loadSelectedSchedule()
        loadSelectedProfile()
    }

    private func loadSelectedSchedule() {
        guard let index = selectedScheduleIndex, configuration.schedules.indices.contains(index) else {
            return
        }
        let schedule = configuration.schedules[index]
        nameField.stringValue = schedule.name
        enabledButton.state = schedule.isEnabled ? .on : .off
        autoAdmitButton.state = schedule.enablesAutoAdmit ? .on : .off
        launchEarlyField.stringValue = String(schedule.launchZoomMinutesEarly)
        startTimePicker.dateValue = date(from: schedule.startTime)

        if let endTime = schedule.endTime {
            usesEndTimeButton.state = .on
            endTimePicker.dateValue = date(from: endTime)
        } else {
            usesEndTimeButton.state = .off
            endTimePicker.dateValue = date(from: TimeOfDay(hour: 20, minute: 0))
        }

        switch schedule.recurrence {
        case .oneTime(let year, let month, let day):
            recurrencePopUp.selectItem(at: 0)
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            oneTimeDatePicker.dateValue = Calendar.current.date(from: components) ?? Date()
            setWeekdays([])
        case .daily:
            recurrencePopUp.selectItem(at: 1)
            setWeekdays([])
        case .selectedWeekdays(let days):
            recurrencePopUp.selectItem(at: 2)
            setWeekdays(days)
        }

        switch schedule.meeting.kind {
        case .meetingID(let identifier):
            meetingKindPopUp.selectItem(at: 0)
            meetingIDField.stringValue = identifier
        case .instantMeeting:
            meetingKindPopUp.selectItem(at: 1)
            meetingIDField.stringValue = ""
        }
        meetingNameField.stringValue = schedule.meeting.name

        if let profileIndex = configuration.accountProfiles.firstIndex(where: { $0.id == schedule.accountProfileID }) {
            accountPopUp.selectItem(at: profileIndex)
        }

        updateFieldVisibility()
    }

    private func storeSelectedSchedule() {
        guard let index = selectedScheduleIndex, configuration.schedules.indices.contains(index) else {
            return
        }
        var schedule = configuration.schedules[index]
        schedule.name = nameField.stringValue.isEmpty ? "Untitled schedule" : nameField.stringValue
        schedule.isEnabled = enabledButton.state == .on
        schedule.enablesAutoAdmit = autoAdmitButton.state == .on
        schedule.launchZoomMinutesEarly = Int(launchEarlyField.stringValue) ?? 2
        schedule.startTime = timeOfDay(from: startTimePicker.dateValue)
        schedule.endTime = usesEndTimeButton.state == .on ? timeOfDay(from: endTimePicker.dateValue) : nil

        switch recurrencePopUp.indexOfSelectedItem {
        case 0:
            let components = Calendar.current.dateComponents(
                [.year, .month, .day],
                from: oneTimeDatePicker.dateValue
            )
            schedule.recurrence = .oneTime(
                year: components.year ?? 2026,
                month: components.month ?? 1,
                day: components.day ?? 1
            )
        case 1:
            schedule.recurrence = .daily
        default:
            schedule.recurrence = .selectedWeekdays(currentWeekdays())
        }

        let meetingName = meetingNameField.stringValue.isEmpty ? schedule.name : meetingNameField.stringValue
        schedule.meeting = MeetingReference(
            name: meetingName,
            kind: meetingKindPopUp.indexOfSelectedItem == 0
                ? .meetingID(meetingIDField.stringValue)
                : .instantMeeting
        )

        let profileIndex = accountPopUp.indexOfSelectedItem
        if configuration.accountProfiles.indices.contains(profileIndex) {
            schedule.accountProfileID = configuration.accountProfiles[profileIndex].id
        }

        configuration.schedules[index] = schedule
    }

    private func loadSelectedProfile() {
        guard let index = selectedProfileIndex, configuration.accountProfiles.indices.contains(index) else {
            return
        }
        let profile = configuration.accountProfiles[index]
        profileNameField.stringValue = profile.name
        profileIdentifierField.stringValue = profile.accountIdentifier
    }

    private func storeSelectedProfile() {
        guard let index = selectedProfileIndex, configuration.accountProfiles.indices.contains(index) else {
            return
        }
        configuration.accountProfiles[index].name = profileNameField.stringValue.isEmpty
            ? "Untitled profile"
            : profileNameField.stringValue
        configuration.accountProfiles[index].accountIdentifier = profileIdentifierField.stringValue
    }

    // MARK: Actions

    @objc private func addSchedule() {
        storeSelectedSchedule()
        let profileID = configuration.accountProfiles.first?.id ?? UUID()
        let schedule = ZoomSchedule(
            name: "New schedule",
            recurrence: .selectedWeekdays([.saturday]),
            startTime: TimeOfDay(hour: 18, minute: 0),
            accountProfileID: profileID,
            meeting: MeetingReference(name: "New meeting", kind: .meetingID(""))
        )
        configuration.schedules.append(schedule)
        scheduleTable.reloadData()
        scheduleTable.selectRowIndexes([configuration.schedules.count - 1], byExtendingSelection: false)
    }

    @objc private func removeSchedule() {
        guard let index = selectedScheduleIndex, configuration.schedules.indices.contains(index) else { return }
        configuration.schedules.remove(at: index)
        scheduleTable.reloadData()
    }

    @objc private func runSelectedScheduleNow() {
        storeSelectedSchedule()
        guard let index = selectedScheduleIndex, configuration.schedules.indices.contains(index) else { return }
        coordinator.update(configuration: configuration)
        coordinator.runNow(configuration.schedules[index])
    }

    @objc private func addProfile() {
        storeSelectedProfile()
        configuration.accountProfiles.append(
            ZoomAccountProfile(name: "New profile", accountIdentifier: "")
        )
        profileTable.reloadData()
        profileTable.selectRowIndexes([configuration.accountProfiles.count - 1], byExtendingSelection: false)
    }

    @objc private func removeProfile() {
        guard let index = selectedProfileIndex, configuration.accountProfiles.indices.contains(index) else { return }
        configuration.accountProfiles.remove(at: index)
        profileTable.reloadData()
        reloadFromConfiguration()
    }

    @objc private func detectAccounts() {
        detectedAccountsPopUp.removeAllItems()
        guard let snapshot = LiveZoomAutomation().readAccountMenu(), !snapshot.entries.isEmpty else {
            detectedAccountsPopUp.addItem(withTitle: "Zoom's account menu could not be read")
            return
        }
        for entry in snapshot.entries {
            let marker = entry.isActive ? "● " : "  "
            detectedAccountsPopUp.addItem(withTitle: marker + (entry.email ?? entry.rawTitle))
        }
    }

    @objc private func useDetectedAccount() {
        let title = detectedAccountsPopUp.titleOfSelectedItem ?? ""
        let cleaned = title.replacingOccurrences(of: "●", with: "").trimmingCharacters(in: .whitespaces)
        guard cleaned.contains("@") else { return }
        profileIdentifierField.stringValue = cleaned
        storeSelectedProfile()
        profileTable.reloadData()
    }

    @objc private func saveSchedules() {
        storeSelectedSchedule()
        storeSelectedProfile()
        coordinator.update(configuration: configuration)
        reloadFromConfiguration()
    }

    @objc private func revert() {
        configuration = coordinator.currentConfiguration
        reloadFromConfiguration()
    }

    @objc private func recurrenceChanged() {
        updateFieldVisibility()
    }

    @objc private func meetingKindChanged() {
        updateFieldVisibility()
    }

    private func updateFieldVisibility() {
        let isOneTime = recurrencePopUp.indexOfSelectedItem == 0
        let isWeekdays = recurrencePopUp.indexOfSelectedItem == 2
        oneTimeDatePicker.isEnabled = isOneTime
        weekdayButtons.forEach { $0.isEnabled = isWeekdays }
        meetingIDField.isEnabled = meetingKindPopUp.indexOfSelectedItem == 0
        endTimePicker.isEnabled = usesEndTimeButton.state == .on
    }

    // MARK: Helpers

    private func currentWeekdays() -> Set<Weekday> {
        var days: Set<Weekday> = []
        for (index, button) in weekdayButtons.enumerated() where button.state == .on {
            if let weekday = Weekday(rawValue: index + 1) { days.insert(weekday) }
        }
        return days
    }

    private func setWeekdays(_ days: Set<Weekday>) {
        for (index, button) in weekdayButtons.enumerated() {
            let weekday = Weekday(rawValue: index + 1)
            button.state = weekday.map(days.contains) == true ? .on : .off
        }
    }

    private func date(from time: TimeOfDay) -> Date {
        Calendar.current.date(
            from: DateComponents(year: 2000, month: 1, day: 1, hour: time.hour, minute: time.minute)
        ) ?? Date()
    }

    private func timeOfDay(from date: Date) -> TimeOfDay {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func integerFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 60
        return formatter
    }

    private func configure(datePicker: NSDatePicker, elements: NSDatePicker.ElementFlags) {
        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = elements
        datePicker.dateValue = Date()
    }

    private func configure(table: NSTableView, columnTitle: String) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.title = columnTitle
        column.width = 200
        table.addTableColumn(column)
        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
    }

    private func scrollView(for table: NSTableView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }
}

extension SchedulerWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === scheduleTable ? configuration.schedules.count : configuration.accountProfiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === scheduleTable {
            guard configuration.schedules.indices.contains(row) else { return nil }
            let schedule = configuration.schedules[row]
            let marker = schedule.isEnabled ? "●" : "○"
            text = "\(marker) \(schedule.name) — \(schedule.recurrence.displayText) \(schedule.startTime.displayText)"
        } else {
            guard configuration.accountProfiles.indices.contains(row) else { return nil }
            let profile = configuration.accountProfiles[row]
            text = "\(profile.name) — \(profile.accountIdentifier)"
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    func tableViewSelectionIsChanging(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === scheduleTable {
            storeSelectedSchedule()
        } else {
            storeSelectedProfile()
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === scheduleTable {
            loadSelectedSchedule()
        } else {
            loadSelectedProfile()
        }
    }
}
