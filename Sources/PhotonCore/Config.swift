import Foundation

public struct Config: Codable {
    public var selectedScopes: [Scope]
    public var customScopes: [CustomScope]

    public init(selectedScopes: [Scope] = [], customScopes: [CustomScope] = []) {
        self.selectedScopes = selectedScopes
        self.customScopes = customScopes
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

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(self) {
            try? data.write(to: Config.configURL)
        }
    }

    // MARK: - All resolved paths

    public var allScopes: [URL] {
        let predefined = selectedScopes.map { $0.path }
        let custom = customScopes.filter { $0.isAvailable }.map { $0.path }
        return predefined + custom
    }
}
