import Foundation
import AppKit
import PhotonCore

// MARK: - SearchResult

/// Unified row model for the overlay. Apps and files collapse into one
/// ranked list, exactly like Spotlight: ranking is pure match quality.
public enum ResultKind {
    case app
    case file
    case directory
}

public struct SearchResult: Identifiable, Hashable {
    public let id: UUID = UUID()
    public let name: String
    public let path: URL
    public let kind: ResultKind
    public let size: Int64?
    public let modificationDate: Date?
    public let icon: NSImage?

    public var displaySize: String? {
        guard let size else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    public var containingFolder: URL {
        path.deletingLastPathComponent()
    }

    /// Path depth (number of components). Lower = closer to root = more likely to be a top-level scan dir.
    var pathDepth: Int {
        path.pathComponents.count
    }

    public var glyph: String {
        switch kind {
        case .app:      return "🅰"
        case .file:     return "📄"
        case .directory: return "📁"
        }
    }
}

private let iconSize: CGFloat = 32

private extension NSWorkspace {
    /// Return an icon scaled to iconSize so SwiftUI renders it at the right pixel size.
    func iconScaled(forFile filePath: String) -> NSImage {
        let icon = icon(forFile: filePath)
        icon.size = NSSize(width: iconSize, height: iconSize)
        return icon
    }
}

public extension SearchResult {
    init(app: App) {
        self.init(name: app.name, path: app.path, kind: .app, size: nil, modificationDate: nil,
                  icon: NSWorkspace.shared.iconScaled(forFile: app.path.path))
    }

    init(file: IndexedFile) {
        let isDir = file.kind == .directory
        let resultKind: ResultKind = file.kind == .directory ? .directory : .file
        self.init(name: file.name, path: file.path, kind: resultKind,
                  size: isDir ? nil : file.size,
                  modificationDate: file.modificationDate,
                  icon: NSWorkspace.shared.iconScaled(forFile: file.path.path))
    }
}

// MARK: - Ranking

extension SearchResult {
    /// Higher is better. Match quality tier is primary; within each tier, kind
    /// breaks ties: **apps > directories > files**. This means typing "app" or
    /// "chrome" immediately surfaces the matching application before any similarly-
    /// named directory or file.
    ///
    /// The ranking pipeline (priority order):
    /// 1. Exact name match (case-insensitive)
    /// 2. Prefix match (name starts with query via `hasPrefix`)
    /// 3. Substring match (name contains query via `contains`)
    /// 4. Path match (query appears in full path)
    ///
    /// Within every tier: app > directory > file, and closer-to-root paths win.
    static func score(_ result: SearchResult, query: String) -> Int {
        let q = query.lowercased()
        let name = result.name.lowercased()

        // Tier 1: exact name match
        if name == q {
            return rank(result.kind, by: .exact)
        }

        // Tier 2: prefix match
        if name.hasPrefix(q) {
            return rank(result.kind, by: .prefix) - name.count
        }

        // Tier 3: substring match
        if name.contains(q) {
            return rank(result.kind, by: .contains) - name.count
        }

        // Tier 4: path contains — last resort
        if result.path.path.lowercased().contains(q) {
            return rank(result.kind, by: .path)
        }

        return -1
    }

    /// Base score for a given kind and tier. Apps beat dirs beat files everywhere.
    private static func rank(_ kind: ResultKind, by tier: ScoreTier) -> Int {
        switch (tier, kind) {
        case (.exact, .app):          return 1_500_000
        case (.exact, .directory):    return 1_000_500
        case (.exact, .file):         return   900_000

        case (.prefix, .app):         return   250_000
        case (.prefix, .directory):   return   200_000
        case (.prefix, .file):        return   100_000

        case (.contains, .app):       return    20_000
        case (.contains, .directory): return    10_000
        case (.contains, .file):      return     5_000

        case (.path, .app):           return       1_500
        case (.path, .directory):     return       1_000
        case (.path, .file):          return         500
        }
    }

    private enum ScoreTier {
        case exact, prefix, contains, path
    }
}

// MARK: - ScanState

@MainActor
final class ScanState: ObservableObject {
    @Published private(set) var results: [SearchResult] = []
    @Published var query: String = ""
    @Published private(set) var isScanning: Bool = false
    @Published var selectedIndex: Int = 0

    /// Computed + ranked view of the list for the current query.
    var visibleResults: [SearchResult] {
        guard !query.isEmpty else { return results }
        return results
            .compactMap { r -> (SearchResult, Int)? in
                let s = SearchResult.score(r, query: query)
                return s > 0 ? (r, s) : nil
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }                // higher score first
                if a.0.pathDepth != b.0.pathDepth { return a.0.pathDepth < b.0.pathDepth }  // fewer path components first
                return a.0.name < b.0.name                         // alphabetical tiebreak
            }
            .map { $0.0 }
    }

    var selectedResult: SearchResult? {
        let v = visibleResults
        guard v.indices.contains(selectedIndex) else { return nil }
        return v[selectedIndex]
    }

    func clampSelection() {
        let count = visibleResults.count
        if count == 0 { selectedIndex = 0; return }
        if selectedIndex >= count { selectedIndex = count - 1 }
        if selectedIndex < 0 { selectedIndex = 0 }
    }

    func moveDown() {
        let count = visibleResults.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + 1) % count
    }

    func moveUp() {
        let count = visibleResults.count
        guard count > 0 else { return }
        selectedIndex = (selectedIndex - 1 + count) % count
    }

    /// Reset just the query and selection, keeping results cached.
    func resetQuery() {
        query = ""
        selectedIndex = 0
    }

    /// Reset to a fresh, empty overlay state (used on full dismiss if needed).
    func reset() {
        query = ""
        results = []
        selectedIndex = 0
    }

    // MARK: - Scanning

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task { @MainActor in
            var config = Config.load()
            if config.selectedScopes.isEmpty { config.selectedScopes = Scope.allCases }
            let scopes = config.allScopes

            var combined: [SearchResult] = []

            // Apps first (Spotlight-like: apps surface near the top by name match).
            let apps = await Task.detached(priority: .userInitiated) {
                AppScanner().scan(extraScopes: scopes)
            }.value
            combined.append(contentsOf: apps.map(SearchResult.init(app:)))

            let filesByScope = await Task.detached(priority: .userInitiated) {
                let scanner = FolderScanner()
                var files: [IndexedFile] = []
                for scope in scopes {
                    files.append(contentsOf: scanner.scan(url: scope))
                }
                return files
            }.value
            combined.append(contentsOf: filesByScope.map(SearchResult.init(file:)))

            self.results = combined.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.isScanning = false
            self.selectedIndex = 0
        }
    }
}
