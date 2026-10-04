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
    case calculator
}

public struct SearchResult: Identifiable, Hashable {
    public let id: UUID = UUID()
    public let name: String
    public let path: URL
    public let kind: ResultKind
    public let size: Int64?
    public let modificationDate: Date?

    /// Loads the icon for this result. Intended to be called once from
    /// the SwiftUI view's `onAppear`, so icon fetching doesn't block rendering.
    func makeIcon() -> NSImage? {
        switch kind {
        case .calculator:
            return NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app")
        case .directory:
            return NSWorkspace.shared.icon(forFile: path.path)
        default:
            return NSWorkspace.shared.iconScaled(forFile: path.path)
        }
    }

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
        case .app:        return "🅰"
        case .file:       return "📄"
        case .directory:  return "📁"
        case .calculator: return "🟰"
        }
    }

    /// The clipboard-ready numeric value for calculator results
    /// (the display string without the leading `= `).
    public var copyValue: String? {
        guard kind == .calculator, name.hasPrefix("= ") else { return nil }
        return String(name.dropFirst(2))
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
        self.init(name: app.name, path: app.path, kind: .app, size: nil, modificationDate: nil)
    }

    init(file: IndexedFile) {
        let resultKind: ResultKind = file.kind == .directory ? .directory : .file
        self.init(name: file.name, path: file.path, kind: resultKind,
                  size: file.size,
                  modificationDate: file.modificationDate)
    }

    /// Synthetic result for an evaluated expression, e.g. name `= 4`.
    /// The path is never opened; it exists to satisfy the result model.
    static func calculator(expression query: String) -> SearchResult? {
        guard let value = PhotonCore.Calculator.evaluate(query) else { return nil }
        return SearchResult(
            name: PhotonCore.Calculator.displayString(for: value),
            path: URL(string: "photon://calculator")!,
            kind: .calculator,
            size: nil,
            modificationDate: nil
        )
    }
}

// MARK: - Ranking

fileprivate func rankScore(_ kind: ResultKind, by tier: ScoreTier) -> Int {
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

    // Calculator results never go through the name-matching ranker; they are
    // pinned to the top of the list by the caller.
    case (_, .calculator):        return       0
    }
}

private enum ScoreTier {
    case exact, prefix, contains, path
}

extension SearchResult {
    /// Higher is better. Used by external consumers (tests, etc.).
    static func score(_ result: SearchResult, query: String) -> Int {
        let q = query.lowercased()
        let name = result.name.lowercased()

        if name == q {
            return rankScore(result.kind, by: .exact)
        }
        if name.hasPrefix(q) {
            return rankScore(result.kind, by: .prefix) - name.count
        }
        if name.contains(q) {
            return rankScore(result.kind, by: .contains) - name.count
        }
        if result.path.path.lowercased().contains(q) {
            return rankScore(result.kind, by: .path)
        }
        return -1
    }
}

// MARK: - ScanState

@MainActor
final class ScanState: ObservableObject {
    @Published private(set) var results: [SearchResult] = []
    @Published var query: String = ""
    @Published private(set) var isScanning: Bool = false
    @Published var selectedIndex: Int = 0
    @Published private(set) var theme: Theme
    /// The folders the user has opted into for file search (apps-only when empty).
    @Published private(set) var scanFolders: [ScanFolder] = []
    /// Bumped every time the overlay reopens, so the view can re-assert
    /// search-field focus (a panel's focus doesn't survive orderOut).
    @Published private(set) var focusGeneration = 0

    func notifyReopen() {
        focusGeneration += 1
    }

    /// Launch history powering the home screen and search boosts.
    let history: HistoryStore

    /// Active color scheme for multi-palette themes (Cyberpunk).
    @Published private(set) var cyberVariant: CyberVariant = .synth

    init(history: HistoryStore = HistoryStore()) {
        self.history = history
        let config = Config.load()
        self.cyberVariant = CyberVariant(rawValue: config.cyberVariant ?? "") ?? .synth
        self.theme = Theme.theme(config.resolvedTheme, variant: config.cyberVariant)
        self.scanFolders = config.scanFolders
        self.hotkeyUsesCommand = config.usesCommandSpace
    }

    /// Switch skins (live) and persist the choice.
    func setTheme(_ kind: ThemeKind) {
        theme = Theme.theme(kind, variant: cyberVariant.rawValue)
        var config = Config.load()
        config.themeID = kind
        config.save()
    }

    /// Switch the Cyberpunk color scheme (live) and persist it.
    func setCyberVariant(_ variant: CyberVariant) {
        cyberVariant = variant
        var config = Config.load()
        config.cyberVariant = variant.rawValue
        config.save()
        if theme.id == .cyberpunk {
            theme = Theme.theme(.cyberpunk, variant: variant.rawValue)
        }
    }

    /// The empty-query home screen: the user's most frequently/recently used
    /// items first (capped), backfilled with apps so it never looks broken.
    /// Files without history are deliberately excluded — no alphabetical dump.
    private var homeResults: [SearchResult] {
        let cap = 15
        var seen = Set<URL>()

        // History items ranked by frecency, then recency, then name.
        var withHistory: [(SearchResult, Double, Date)] = []
        for r in results where !seen.contains(r.path) {
            guard let entry = history.entry(for: r.path.path) else { continue }
            seen.insert(r.path)
            withHistory.append((r, HistoryStore.score(launchCount: entry.launchCount,
                                                       lastLaunchedAt: entry.lastLaunchedAt),
                                entry.lastLaunchedAt))
        }
        withHistory.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
        }
        var out = withHistory.prefix(cap).map { $0.0 }

        // Backfill remaining rows with apps that have no history.
        if out.count < cap {
            for r in results where out.count < cap {
                guard r.kind == .app, !seen.contains(r.path) else { continue }
                seen.insert(r.path)
                out.append(r)
            }
        }
        return out
    }

    /// Computed + ranked view of the list for the current query.
    /// Inlined here to avoid file-level globals (concurrency-safety).
    var visibleResults: [SearchResult] {
        // A query that fully parses as an arithmetic expression always gets a
        // pinned calculator row, independent of the app/file index.
        let calculatorResult = SearchResult.calculator(expression: query)

        guard !query.isEmpty else { return homeResults }
        guard !results.isEmpty else { return calculatorResult.map { [$0] } ?? [] }

        let q = query.lowercased()
        let ranked = results
            .compactMap { r -> (SearchResult, Double)? in
                let name = r.name.lowercased()

                let tierScore: Int
                if name == q {
                    tierScore = rankScore(r.kind, by: .exact)
                } else if name.hasPrefix(q) {
                    tierScore = rankScore(r.kind, by: .prefix) - name.count
                } else if name.contains(q) {
                    tierScore = rankScore(r.kind, by: .contains) - name.count
                } else if r.path.path.lowercased().contains(q) {
                    tierScore = rankScore(r.kind, by: .path)
                } else {
                    return nil
                }

                // Bounded frecency boost (max 2x): reorders within a match
                // tier but can never flip across tiers. No history → 1.0.
                let boost = 1.0 + min(history.frecencyScore(for: r.path.path), 1.0)
                return (r, Double(tierScore) * boost)
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.pathDepth != b.0.pathDepth { return a.0.pathDepth < b.0.pathDepth }
                return a.0.name < b.0.name
            }
            .map { $0.0 }

        if let calculatorResult {
            return [calculatorResult] + ranked
        }
        return ranked
    }

    var selectedResult: SearchResult? {
        let v = visibleResults
        guard v.indices.contains(selectedIndex) else { return nil }
        return v[selectedIndex]
    }

    /// Submit the nth visible result via keyboard slot (⌘1–9).
    /// Returns the result to submit, or nil when the slot is empty.
    func slotResult(_ number: Int) -> SearchResult? {
        guard (1...9).contains(number) else { return nil }
        let v = visibleResults
        guard v.indices.contains(number - 1) else { return nil }
        return v[number - 1]
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

    /// Record a launch and refresh the list: history itself isn't observable,
    /// so without this the home screen wouldn't reorder until the next
    /// query-driven re-render (or relaunch).
    func recordLaunch(path: String) {
        history.record(path: path)
        objectWillChange.send()
    }

    /// Internal injection point for ranking tests; production populates
    /// results exclusively via `scan()`.
    func injectResults(_ newResults: [SearchResult]) {
        results = newResults
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        Task { @MainActor in
            let config = Config.load()
            // Apps always. Folders only when explicitly opted in — an empty
            // list means apps-only, never an implicit all-scope scan.
            let folders = config.availableScanFolders

            var combined: [SearchResult] = []

            // Apps first (Spotlight-like: apps surface near the top by name match).
            let apps = await Task.detached(priority: .userInitiated) {
                AppScanner().scan()
            }.value
            combined.append(contentsOf: apps.map(SearchResult.init(app:)))

            let filesByScope = await Task.detached(priority: .userInitiated) {
                let scanner = FolderScanner()
                var files: [IndexedFile] = []
                for folder in folders {
                    files.append(contentsOf: scanner.scan(url: folder.path, depth: folder.depth, fileCap: folder.fileCap))
                }
                return files
            }.value
            combined.append(contentsOf: filesByScope.map(SearchResult.init(file:)))

            self.results = combined.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.isScanning = false
            self.selectedIndex = 0
        }
    }

    // MARK: - Scan folder management

    /// Add a folder (granted via the native picker), persist, and re-scan.
    func addScanFolder(_ folder: ScanFolder) {
        var config = Config.load()
        guard !config.scanFolders.contains(where: { $0.path == folder.path }) else { return }
        config.scanFolders.append(folder)
        config.save()
        scanFolders = config.scanFolders
        scan()
    }

    /// Remove a folder, persist, and re-scan.
    func removeScanFolder(_ folder: ScanFolder) {
        var config = Config.load()
        config.scanFolders.removeAll { $0.path == folder.path }
        config.save()
        scanFolders = config.scanFolders
        scan()
    }

    /// Update a folder's limits (depth/cap), persist, and re-scan.
    func updateScanFolder(_ folder: ScanFolder) {
        var config = Config.load()
        if let idx = config.scanFolders.firstIndex(where: { $0.path == folder.path }) {
            config.scanFolders[idx] = folder
            config.save()
            scanFolders = config.scanFolders
            scan()
        }
    }

    // MARK: - Hotkey

    /// Posted (on the main queue) after the trigger preference changes, so the
    /// app delegate can re-register the Carbon hotkey without a relaunch.
    static let hotkeyChangedNotification = Notification.Name("photon.hotkeyChanged")

    /// Whether ⌘Space (instead of ⌥Space) currently triggers the overlay.
    /// Published so the settings radio rows update instantly on toggle.
    @Published private(set) var hotkeyUsesCommand: Bool = false

    /// Select the trigger: true = ⌘Space, false = ⌥Space (default). Persists
    /// and notifies the app delegate to re-register the hotkey live.
    func setHotkeyUsesCommand(_ enabled: Bool) {
        var config = Config.load()
        config.hotkeyUsesCommand = enabled
        config.save()
        hotkeyUsesCommand = enabled
        NotificationCenter.default.post(name: Self.hotkeyChangedNotification, object: nil)
    }
}
