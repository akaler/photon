import Foundation

/// A single recorded launch of an app or file from the Photon overlay.
public struct HistoryEntry: Codable, Sendable, Equatable {
    public var path: String
    public var launchCount: Int
    public var lastLaunchedAt: Date

    public init(path: String, launchCount: Int = 1, lastLaunchedAt: Date = Date()) {
        self.path = path
        self.launchCount = launchCount
        self.lastLaunchedAt = lastLaunchedAt
    }
}

/// Persistent record of items opened via Photon, used to rank the home
/// screen (empty query) and boost search results. Stored as JSON at
/// `~/.config/photon/history.json`, capped at `maxEntries`.
public final class HistoryStore {
    public static let maxEntries = 200

    private var entries: [String: HistoryEntry] = [:]
    private let lock = NSLock()
    private let fileURL: URL

    // MARK: - Init / loading

    /// - Parameter fileURL: Overrides the storage location (used by tests).
    ///   When nil, defaults to `~/.config/photon/history.json`.
    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/photon", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("history.json")
        }
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([String: HistoryEntry].self, from: data) else { return }
        // Prune entries whose targets no longer exist.
        entries = decoded.filter { FileManager.default.fileExists(atPath: $0.value.path) }
    }

    // MARK: - Recording

    /// Record a launch of `path`. Re-recording increments the count and
    /// refreshes the timestamp instead of creating a duplicate.
    public func record(path: String, now: Date = Date()) {
        lock.lock()
        var entry = entries[path] ?? HistoryEntry(path: path, launchCount: 0, lastLaunchedAt: now)
        entry.launchCount += 1
        entry.lastLaunchedAt = now
        entries[path] = entry
        evictIfNeeded()
        let snapshot = entries
        lock.unlock()
        saveInBackground(snapshot)
    }

    /// Evict the lowest-scoring entry when over the cap. Ties break toward
    /// the stalest entry, then alphabetical, so eviction is deterministic.
    private func evictIfNeeded() {
        guard entries.count > Self.maxEntries else { return }
        let now = Date()
        let lowest = entries.values.min { a, b in
            let sa = Self.score(launchCount: a.launchCount, lastLaunchedAt: a.lastLaunchedAt, now: now)
            let sb = Self.score(launchCount: b.launchCount, lastLaunchedAt: b.lastLaunchedAt, now: now)
            if sa != sb { return sa < sb }
            if a.lastLaunchedAt != b.lastLaunchedAt { return a.lastLaunchedAt < b.lastLaunchedAt }
            return a.path < b.path
        }
        if let lowest { entries.removeValue(forKey: lowest.path) }
    }

    // MARK: - Lookup

    public func entry(for path: String) -> HistoryEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries[path]
    }

    /// All entries sorted by frecency score (descending).
    public var allEntries: [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        return entries.values.sorted {
            Self.score(launchCount: $0.launchCount, lastLaunchedAt: $0.lastLaunchedAt, now: now) >
            Self.score(launchCount: $1.launchCount, lastLaunchedAt: $1.lastLaunchedAt, now: now)
        }
    }

    // MARK: - Scoring

    /// Frecency score: `launchCount / (daysSinceLastLaunch + 2)`.
    /// Smooth decay — 10 uses a month ago ≈ 1 use today — so both axes matter.
    public static func score(launchCount: Int, lastLaunchedAt: Date, now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(lastLaunchedAt)) / 86_400
        return Double(launchCount) / (days + 2)
    }

    /// Score for a path; 0 when the path has no history.
    public func frecencyScore(for path: String, now: Date = Date()) -> Double {
        guard let entry = entry(for: path) else { return 0 }
        return Self.score(launchCount: entry.launchCount, lastLaunchedAt: entry.lastLaunchedAt, now: now)
    }

    // MARK: - Persistence

    /// Synchronously write the current entries to disk (used by tests and
    /// for flush-on-demand; normal recording saves in the background).
    public func save() {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        write(snapshot)
    }

    private func saveInBackground(_ snapshot: [String: HistoryEntry]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.write(snapshot)
        }
    }

    private func write(_ snapshot: [String: HistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
