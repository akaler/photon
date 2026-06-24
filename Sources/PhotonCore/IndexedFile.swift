import Foundation

public enum FileKind: Sendable {
    case file
    case directory
}

public struct IndexedFile: Sendable {
    public let name: String
    public let path: URL
    public let size: Int64
    public let fileExtension: String?
    public let modificationDate: Date
    public let kind: FileKind

    public init(name: String, path: URL, size: Int64, fileExtension: String?, modificationDate: Date, kind: FileKind = .file) {
        self.name = name
        self.path = path
        self.size = size
        self.fileExtension = fileExtension
        self.modificationDate = modificationDate
        self.kind = kind
    }

    public var fileExtensionDisplay: String {
        fileExtension.map { ".\($0)" } ?? ""
    }

    public var displaySize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
