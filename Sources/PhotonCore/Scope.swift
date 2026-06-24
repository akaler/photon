import Foundation

public enum Scope: String, CaseIterable, Hashable, Codable {
    case downloads = "Downloads"
    case documents = "Documents"
    case desktop = "Desktop"

    public var label: String {
        rawValue
    }

    public var path: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: "\(home)/\(rawValue)")
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }
}

public struct CustomScope: Hashable, Codable {
    public let name: String
    public let path: URL

    public init(name: String, path: URL) {
        self.name = name
        self.path = path
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }
}
