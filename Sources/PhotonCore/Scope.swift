import Foundation

/// A folder the user chose to index for file search. The app is apps-only by
/// default; every entry here is an explicit opt-in granted through the native
/// folder picker. Each folder carries its own recursion limits so indexing
/// stays bounded on any machine.
public struct ScanFolder: Codable, Hashable, Sendable {
    public var name: String
    public var path: URL
    /// Max directory depth to recurse into (1 = the folder itself only).
    public var depth: Int
    /// Max number of files to index from this folder (directories excluded).
    public var fileCap: Int

    public init(name: String, path: URL, depth: Int = 3, fileCap: Int = 5000) {
        self.name = name
        self.path = path
        self.depth = depth
        self.fileCap = fileCap
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: path.path)
    }
}

/// The original predefined scopes (Desktop/Documents/Downloads). Kept for
/// backward-compatible decoding of older configs and as a CLI convenience for
/// adding standard folders. The overlay no longer preselects any of them.
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

/// Legacy free-form scope; only used to decode pre-`ScanFolder` configs.
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
