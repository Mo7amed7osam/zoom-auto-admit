import Foundation

/// Imports an official student roster from CSV or pasted text.
///
/// Deliberately forgiving about shape — real rosters arrive as an export with
/// headers, or as a column of names pasted out of a message — and deliberately
/// strict about identity: importing twice must not create two of every student,
/// so existing students are matched and updated rather than appended.
public enum RosterImporter {
    public struct ImportResult: Equatable {
        public let students: [Student]
        public let addedCount: Int
        public let updatedCount: Int
        /// Lines that carried no usable name, reported rather than silently lost.
        public let skippedLines: [String]

        public init(students: [Student], addedCount: Int, updatedCount: Int, skippedLines: [String]) {
            self.students = students
            self.addedCount = addedCount
            self.updatedCount = updatedCount
            self.skippedLines = skippedLines
        }
    }

    public struct ParsedRow: Equatable {
        public let name: String
        public let externalID: String?
        public let email: String?
    }

    private static let nameHeaders = ["name", "student", "student name", "full name", "الاسم", "اسم الطالب"]
    private static let idHeaders = ["id", "student id", "studentid", "code", "كود"]
    private static let emailHeaders = ["email", "e-mail", "mail", "البريد"]

    /// Parses CSV or newline-separated text into rows.
    public static func parse(_ text: String) -> (rows: [ParsedRow], skipped: [String]) {
        var rows: [ParsedRow] = []
        var skipped: [String] = []

        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var nameIndex = 0
        var idIndex: Int?
        var emailIndex: Int?
        var startIndex = 0

        // A header row is only honoured when it actually names a column;
        // otherwise the first line is a student like any other.
        if let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let fields = splitCSVLine(first).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if let index = fields.firstIndex(where: { nameHeaders.contains($0) }) {
                nameIndex = index
                idIndex = fields.firstIndex { idHeaders.contains($0) }
                emailIndex = fields.firstIndex { emailHeaders.contains($0) }
                startIndex = (lines.firstIndex(of: first) ?? 0) + 1
            }
        }

        for line in lines.dropFirst(startIndex) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let fields = splitCSVLine(line)
            let name = fields.indices.contains(nameIndex)
                ? fields[nameIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            guard !name.isEmpty, name.rangeOfCharacter(from: .letters) != nil else {
                skipped.append(trimmed)
                continue
            }

            func value(at index: Int?) -> String? {
                guard let index, fields.indices.contains(index) else { return nil }
                let value = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }

            rows.append(ParsedRow(name: name, externalID: value(at: idIndex), email: value(at: emailIndex)))
        }

        return (rows, skipped)
    }

    /// Merges parsed rows into an existing roster.
    ///
    /// Matching is by external ID first, then by normalised name. Learned
    /// aliases and identifiers of existing students are preserved, because a
    /// re-import of the class list must not discard what the app has learned.
    public static func merge(_ text: String, into existing: [Student]) -> ImportResult {
        let parsed = parse(text)
        var students = existing
        var added = 0
        var updated = 0

        for row in parsed.rows {
            let normalized = NameNormalizer.normalize(row.name)

            let index = students.firstIndex {
                if let externalID = row.externalID, let theirs = $0.externalID, !theirs.isEmpty {
                    return theirs.caseInsensitiveCompare(externalID) == .orderedSame
                }
                return $0.normalizedOfficialName == normalized
            }

            if let index {
                students[index].officialName = row.name
                if let externalID = row.externalID { students[index].externalID = externalID }
                if let email = row.email { students[index].email = email }
                updated += 1
            } else {
                students.append(Student(
                    officialName: row.name,
                    externalID: row.externalID,
                    email: row.email
                ))
                added += 1
            }
        }

        return ImportResult(
            students: students,
            addedCount: added,
            updatedCount: updated,
            skippedLines: parsed.skipped
        )
    }

    /// Minimal CSV field splitting with quote support.
    static func splitCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            current.append("\"")   // escaped quote
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "," || character == ";" || character == "\t" {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        fields.append(current)
        return fields
    }
}
