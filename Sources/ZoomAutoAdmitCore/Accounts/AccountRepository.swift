import Foundation

public protocol AccountRepository {
    func load() throws -> [ZoomAccountMetadata]
    func save(_ accounts: [ZoomAccountMetadata]) throws
}

public final class FileAccountRepository: AccountRepository {
    public let location: URL
    private let fileManager: FileManager

    public init(location: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let location {
            self.location = location
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.location = support
                .appendingPathComponent("Zoom Auto Admit", isDirectory: true)
                .appendingPathComponent("accounts.json")
        }
    }

    public func load() throws -> [ZoomAccountMetadata] {
        guard fileManager.fileExists(atPath: location.path) else { return [] }
        return try JSONDecoder().decode([ZoomAccountMetadata].self, from: Data(contentsOf: location))
    }

    public func save(_ accounts: [ZoomAccountMetadata]) throws {
        try fileManager.createDirectory(
            at: location.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(accounts)
        try data.write(to: location, options: .atomic)
    }
}
