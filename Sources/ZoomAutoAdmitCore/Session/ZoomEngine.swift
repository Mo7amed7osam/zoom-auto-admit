import Foundation

public enum ZoomEngine: String, Codable, Equatable {
    case desktop
    case web
}

public struct SessionRequest: Equatable, Identifiable {
    public var id: UUID
    public var account: ZoomAccount
    public var meetingURL: URL
    public var startTime: Date

    public init(
        id: UUID = UUID(),
        account: ZoomAccount,
        meetingURL: URL,
        startTime: Date
    ) {
        self.id = id
        self.account = account
        self.meetingURL = meetingURL
        self.startTime = startTime
    }
}
