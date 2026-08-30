import Foundation

public enum ZoomPreferredEngine: String, Codable, CaseIterable, Equatable, Hashable {
    case desktop
    case web
    case auto
}

public struct ZoomAccount: Identifiable, Equatable, Hashable {
    public var id: UUID
    public var displayName: String
    public var email: String
    public var preferredEngine: ZoomPreferredEngine

    public init(
        id: UUID = UUID(),
        displayName: String,
        email: String,
        preferredEngine: ZoomPreferredEngine = .auto
    ) {
        self.id = id
        self.displayName = displayName
        self.email = email
        self.preferredEngine = preferredEngine
    }
}

public struct ZoomAccountDraft: Equatable {
    public var displayName: String
    public var email: String
    public var password: String
    public var preferredEngine: ZoomPreferredEngine

    public init(
        displayName: String,
        email: String,
        password: String,
        preferredEngine: ZoomPreferredEngine = .auto
    ) {
        self.displayName = displayName
        self.email = email
        self.password = password
        self.preferredEngine = preferredEngine
    }
}

public struct ZoomAccountMetadata: Codable, Equatable, Identifiable {
    public var id: UUID
    public var displayName: String
    public var preferredEngine: ZoomPreferredEngine

    public init(id: UUID, displayName: String, preferredEngine: ZoomPreferredEngine) {
        self.id = id
        self.displayName = displayName
        self.preferredEngine = preferredEngine
    }
}
