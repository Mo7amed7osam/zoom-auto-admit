import Foundation

/// CSV export of a finalized register.
public enum AttendanceExport {
    /// Column names say what the evidence actually is. "Join Time" and "Leave
    /// Time" would be a claim periodic snapshots cannot support.
    public static let header = [
        "Official Student Name",
        "Status",
        "Matched Zoom Name",
        "Match Source",
        "Confidence",
        "First Observed",
        "Last Observed",
        "Observation Count"
    ]

    public static func csv(for session: AttendanceSession, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone

        var lines = [header.map(escape).joined(separator: ",")]

        for record in session.recordsInRosterOrder {
            let observation = record.matchedObservationID.flatMap { session.observation(withID: $0) }
            let fields = [
                record.studentName,
                displayStatus(record.status),
                record.matchedZoomName ?? "",
                record.matchSource == .none ? "" : record.matchSource.rawValue,
                record.confidence.map { String(format: "%.2f", $0) } ?? "",
                observation?.firstObservedAt.map { formatter.string(from: $0) } ?? "",
                observation?.lastObservedAt.map { formatter.string(from: $0) } ?? "",
                observation.map { String($0.observationCount) } ?? ""
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// The whole register as a numbered list, in roster order.
    ///
    /// Built for transcription: one student per line, in the order the official
    /// list is already in, so reading it out onto another system is a straight
    /// walk down the page with nothing to search for.
    public static func rosterOrderReport(
        for session: AttendanceSession,
        includeZoomNames: Bool = true
    ) -> String {
        let ordered = session.recordsInRosterOrder
        guard !ordered.isEmpty else { return "No students on this register." }

        let width = String(ordered.count).count
        var lines: [String] = []
        for (index, record) in ordered.enumerated() {
            // Padded on the left, so the dots line up in a column and the list
            // reads as a numbered list rather than "1 ." and "10.".
            let raw = String(index + 1)
            let number = String(repeating: " ", count: max(0, width - raw.count)) + raw
            var line = "\(number). \(record.studentName) — \(displayStatus(record.status))"
            if includeZoomNames, let zoomName = record.matchedZoomName, !zoomName.isEmpty {
                line += " (\(zoomName))"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The absence list, which is the everyday operational need.
    public static func absentNames(in session: AttendanceSession) -> [String] {
        session.records
            .filter { $0.status == .absent }
            .map(\.studentName)
            .sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    public static func absenceReport(for session: AttendanceSession) -> String {
        let absent = absentNames(in: session)
        guard !absent.isEmpty else { return "Absent: none" }
        return (["Absent:"] + absent.map { "- \($0)" }).joined(separator: "\n")
    }

    public static func displayStatus(_ status: AttendanceStatus) -> String {
        switch status {
        case .present: return "Present"
        case .absent: return "Absent"
        case .needsReview: return "Needs Review"
        case .notSeenYet: return "Not Seen Yet"
        }
    }

    /// Quotes a field only when it needs it, and doubles embedded quotes.
    static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

/// Attendance history on disk.
///
/// One JSON file per session in Application Support, so a corrupt or unreadable
/// file can only ever cost one meeting's register rather than the archive.
public final class AttendanceStore {
    public static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("Zoom Auto Admit", isDirectory: true)
            .appendingPathComponent("Attendance", isDirectory: true)
    }()

    private let directory: URL
    private let queue = DispatchQueue(label: "com.mohamedhosam.ZoomAutoAdmit.attendance-store")

    public init(directory: URL = AttendanceStore.defaultDirectory) {
        self.directory = directory
    }

    public var location: URL { directory }

    @discardableResult
    public func save(_ session: AttendanceSession) -> Bool {
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try Self.encoder.encode(session)
                try data.write(to: url(for: session.id), options: .atomic)
                return true
            } catch {
                return false
            }
        }
    }

    public func load(id: UUID) -> AttendanceSession? {
        queue.sync {
            guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
            return try? Self.decoder.decode(AttendanceSession.self, from: data)
        }
    }

    /// Newest first. Unreadable files are skipped rather than failing the list.
    public func loadAll() -> [AttendanceSession] {
        queue.sync {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else {
                return []
            }
            return files
                .filter { $0.pathExtension == "json" }
                .compactMap { try? Data(contentsOf: $0) }
                .compactMap { try? Self.decoder.decode(AttendanceSession.self, from: $0) }
                .sorted { $0.startedAt > $1.startedAt }
        }
    }

    public func sessions(forGroup groupID: UUID) -> [AttendanceSession] {
        loadAll().filter { $0.groupID == groupID }
    }

    @discardableResult
    public func delete(id: UUID) -> Bool {
        queue.sync { (try? FileManager.default.removeItem(at: url(for: id))) != nil }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
