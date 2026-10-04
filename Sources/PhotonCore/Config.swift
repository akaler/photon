import Foundation

public struct Config: Codable {
    /// Explicit opt-in list of folders to index for file search. Empty by
    /// default (apps-only). Never implicitly falls back to "all scopes".
    public var scanFolders: [ScanFolder]
    /// Active overlay skin. Optional for backward compatibility with
    /// pre-existing config files; nil decodes as the Carbon Solid default.
    public var themeID: ThemeKind?
    /// When true, the overlay trigger is ⌘Space instead of the default ⌥Space.
    /// Optional so older configs decode unchanged (nil = ⌥Space).
    public var hotkeyUsesCommand: Bool?

    public init(scanFolders: [ScanFolder] = [], themeID: ThemeKind? = nil, hotkeyUsesCommand: Bool? = nil) {
        self.scanFolders = scanFolders
        self.themeID = themeID
        self.hotkeyUsesCommand = hotkeyUsesCommand
    }

    // MARK: - Codable (backward compatible with pre-ScanFolder configs)

    private enum CodingKeys: String, CodingKey {
        case scanFolders
        case themeID
        case hotkeyUsesCommand
        // legacy keys
        case selectedScopes
        case customScopes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        if let folders = try c.decodeIfPresent([ScanFolder].self, forKey: .scanFolders) {
            self.scanFolders = folders
        } else {
            // Legacy config: selectedScopes (predefined) + customScopes.
            var folders: [ScanFolder] = []
            if let scopes = try c.decodeIfPresent([Scope].self, forKey: .selectedScopes) {
                folders += scopes.map { ScanFolder(name: $0.label, path: $0.path) }
            }
            if let customs = try c.decodeIfPresent([CustomScope].self, forKey: .customScopes) {
                folders += customs.map { ScanFolder(name: $0.name, path: $0.path) }
            }
            self.scanFolders = folders
        }

        self.themeID = try c.decodeIfPresent(ThemeKind?.self, forKey: .themeID) ?? nil
        self.hotkeyUsesCommand = try c.decodeIfPresent(Bool.self, forKey: .hotkeyUsesCommand) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scanFolders, forKey: .scanFolders)
        try c.encodeIfPresent(themeID, forKey: .themeID)
        try c.encodeIfPresent(hotkeyUsesCommand, forKey: .hotkeyUsesCommand)
    }

    /// The resolved trigger modifier: ⌘Space when opted in, otherwise ⌥Space.
    public var usesCommandSpace: Bool {
        hotkeyUsesCommand == true
    }

    // MARK: - Persistence

    private static var configURL: URL {
        let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/photon")
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        return configDir.appendingPathComponent("config.json")
    }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL) else {
            return Config()
        }
        do {
            let decoder = JSONDecoder()
            let config = try decoder.decode(Config.self, from: data)
            return config
        } catch {
            print("Warning: Could not parse config: \(error)")
            return Config()
        }
    }

    /// The active theme, defaulting to Carbon Solid when unset.
    public var resolvedTheme: ThemeKind {
        themeID ?? .carbonSolid
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(self) {
            try? data.write(to: Config.configURL)
        }
    }

    // MARK: - Folders

    /// The folders available to scan (existing on disk), each with its limits.
    public var availableScanFolders: [ScanFolder] {
        scanFolders.filter { $0.isAvailable }
    }
}
