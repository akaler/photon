import Foundation

public struct App: Sendable {
    public let name: String
    public let path: URL

    public init(name: String, path: URL) {
        self.name = name
        self.path = path
    }
}
