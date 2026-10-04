import Testing
@testable import PhotonCore
@testable import photon_overlay
import Foundation

@Test func folderScanner_indexes_files_recursively() async throws {
    // Create temp directory structure
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("photon_test_\(UUID().uuidString)")
    let subDir = tempDir.appendingPathComponent("subdir")
    try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

    // Add test files
    let file1 = "hello.txt"
    let file2 = "data.json"
    let file3 = "image.png"

    FileManager.default.createFile(atPath: tempDir.appendingPathComponent(file1).path, contents: "test".data(using: .utf8))
    FileManager.default.createFile(atPath: subDir.appendingPathComponent(file2).path, contents: "{}".data(using: .utf8))
    FileManager.default.createFile(atPath: subDir.appendingPathComponent(file3).path, contents: Data(repeating: 0, count: 1024))

    // Add a hidden file that should be skipped
    FileManager.default.createFile(atPath: tempDir.appendingPathComponent(".hidden").path, contents: "secret".data(using: .utf8))

    defer {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // Scan
    let scanner = FolderScanner()
    let results = scanner.scan(path: tempDir.path, showProgress: false)

    #expect(results.count == 4, "Expected 4 entries (3 files + subdir), got \(results.count)")
    #expect(results.contains { $0.name == file1 })
    #expect(results.contains { $0.name == file2 })
    #expect(results.contains { $0.name == file3 })
    #expect(results.contains { $0.name == "subdir" }, "Directories are indexed so they can match queries")
    #expect(!results.contains { $0.name == ".hidden" }, "Hidden file should be skipped")
}

@Test func folderScanner_skips_nonexistent_directory() async throws {
    let scanner = FolderScanner()
    let results = scanner.scan(path: "/nonexistent/path/abc123", showProgress: false)
    #expect(results.isEmpty)
}

@Test func indexedFile_has_display_size() async throws {
    let file = IndexedFile(
        name: "test.bin",
        path: URL(fileURLWithPath: "/tmp/test.bin"),
        size: 1_048_576, // 1 MB
        fileExtension: "bin",
        modificationDate: Date()
    )

    let sizeStr = file.displaySize
    #expect(!sizeStr.isEmpty)
    #expect(sizeStr.range(of: "1", options: .backwards) != nil)
}

@Test func _debug_terminal_scan() {
    let apps = AppScanner().scan(showProgress: false)
    print("DEBUG total apps = \(apps.count)")
    let terminal = apps.filter { $0.name.lowercased().contains("terminal") }
    print("DEBUG terminal matches = \(terminal.map { $0.path.path })")
    #expect(!terminal.isEmpty, "Terminal.app should be found via Utilities recursion")
}

// MARK: - Inline Calculator (add-calculator)

@Test func calculator_basicOperations() {
    func eval(_ s: String) -> Double { Calculator.evaluate(s)! }

    #expect(eval("2+2") == 4)
    #expect(eval("10-4") == 6)
    #expect(eval("6*7") == 42)
    #expect(eval("10/4") == 2.5)
    #expect(eval("10%3") == 1)
    #expect(eval("(4+2)*3") == 18)
    #expect(eval("  7 * 6  ") == 42)
    #expect(eval("42") == 42)
    #expect(eval(".5*2") == 1)
    #expect(eval("-5 + 3") == -2)
    #expect(eval("2--3") == 5)
}

@Test func calculator_precedenceAndPower() {
    func eval(_ s: String) -> Double { Calculator.evaluate(s)! }

    #expect(eval("2+3*4") == 14)
    #expect(eval("(2+3)*4") == 20)
    #expect(eval("2^10") == 1024)
    #expect(eval("2^3^2") == 512) // right-associative
    #expect(eval("-2^2") == 4)    // unary binds tighter than ^
    #expect(eval("100/10/5") == 2) // left-associative division
}

@Test func calculator_invalidInputReturnsNil() {
    for bad in ["2+", "+2*", "(2+3", "2+3)", "abc", "2024-budget", "3.5mm-jack",
                "2 2", "", "sin(30)", "2**3", "1..2", ")(", "1,000+1"] {
        #expect(Calculator.evaluate(bad) == nil, "'\(bad)' should not evaluate")
    }
}

@Test func calculator_nonFiniteResultsRejected() {
    #expect(Calculator.evaluate("5/0") == nil)
    #expect(Calculator.evaluate("5%0") == nil)
}

@Test func calculator_displayStringFormatting() {
    #expect(Calculator.displayString(for: 4) == "= 4")
    #expect(Calculator.displayString(for: 2.5) == "= 2.5")
    #expect(Calculator.displayString(for: 1024) == "= 1024")
    // Floating-point noise trimmed: 0.1+0.2 should not print ...0004
    let noisy = Calculator.evaluate("0.1+0.2")!
    #expect(Calculator.displayString(for: noisy) == "= 0.3")
}

@Test func calculator_searchResultFactory() {
    let result = SearchResult.calculator(expression: "6*7")
    #expect(result != nil)
    #expect(result?.kind == .calculator)
    #expect(result?.name == "= 42")
    #expect(result?.copyValue == "42")

    // Non-expressions produce no result at all.
    #expect(SearchResult.calculator(expression: "2024-budget") == nil)
    #expect(SearchResult.calculator(expression: "5/0") == nil)
}

@Test @MainActor func calculator_row_present_with_empty_index() {
    // Before any scan completes, results is empty — the calculator row must
    // still appear for a valid expression.
    let state = ScanState()
    state.query = "7+7"
    let visible = state.visibleResults
    #expect(visible.count == 1)
    #expect(visible.first?.kind == .calculator)
    #expect(visible.first?.name == "= 14")
}

@Test @MainActor func calculator_row_absent_for_non_expression() {
    let state = ScanState()
    state.query = "2+"
    #expect(state.visibleResults.isEmpty)
}

// MARK: - Launch History & Frecency Ranking (add-frecency-ranking)

/// Creates a real file on disk (history prunes dead paths on load).
private func makeTempFile(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("photon_hist_\(name)_\(UUID().uuidString)")
    FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
    return url
}

@Test func historyStore_recordsAndIncrements() {
    let file = makeTempFile("a")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = HistoryStore(fileURL: URL(fileURLWithPath: "/dev/null")) // no persistence

    store.record(path: file.path, now: Date(timeIntervalSince1970: 1_000))
    store.record(path: file.path, now: Date(timeIntervalSince1970: 2_000))

    let entry = store.entry(for: file.path)
    #expect(entry != nil)
    #expect(entry?.launchCount == 2)
    #expect(entry?.lastLaunchedAt == Date(timeIntervalSince1970: 2_000))
}

@Test func historyStore_persistsAcrossInstances() throws {
    let file = makeTempFile("b")
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("hist_\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: storeURL)
    }

    let store1 = HistoryStore(fileURL: storeURL)
    store1.record(path: file.path, now: Date(timeIntervalSince1970: 5_000))
    store1.save()

    let store2 = HistoryStore(fileURL: storeURL)
    #expect(store2.entry(for: file.path)?.launchCount == 1)
}

@Test func historyStore_prunesDeadPathsOnLoad() throws {
    let live = makeTempFile("live")
    let dead = makeTempFile("dead")
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("hist_\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: live)
        try? FileManager.default.removeItem(at: storeURL)
    }

    let store1 = HistoryStore(fileURL: storeURL)
    store1.record(path: live.path, now: Date(timeIntervalSince1970: 1_000))
    store1.record(path: dead.path, now: Date(timeIntervalSince1970: 1_000))
    store1.save()
    try FileManager.default.removeItem(at: dead) // delete after save

    let store2 = HistoryStore(fileURL: storeURL)
    #expect(store2.entry(for: live.path) != nil)
    #expect(store2.entry(for: dead.path) == nil)
}

@Test func historyStore_capsEntriesAndEvictsLowestScore() {
    let store = HistoryStore(fileURL: URL(fileURLWithPath: "/dev/null"))
    let base = Date(timeIntervalSince1970: 1_000_000)

    // A hot entry (5 launches → highest score), recorded first so the
    // subsequent single-launch records are what fill the store to its cap.
    for _ in 0..<5 { store.record(path: "/fake/hot", now: base.addingTimeInterval(10_000)) }
    // 198 single-launch entries with increasing timestamps
    // (1 hot + 198 singles + 1 cold = 200, exactly at the cap)
    for i in 0..<198 {
        store.record(path: "/fake/entry-\(i)", now: base.addingTimeInterval(Double(i)))
    }
    store.record(path: "/fake/cold", now: base.addingTimeInterval(20_000))

    #expect(store.allEntries.count == 200) // exactly at cap

    // Push one more over the cap: the deterministic eviction tie-break
    // (lowest score → stalest → alphabetical) removes entry-0.
    store.record(path: "/fake/another-cold", now: base.addingTimeInterval(30_000))
    #expect(store.allEntries.count == 200)
    #expect(store.entry(for: "/fake/hot") != nil, "hot entry survives eviction")
    #expect(store.entry(for: "/fake/cold") != nil)
    #expect(store.entry(for: "/fake/entry-0") == nil, "stalest low-score entry evicted")
    #expect(store.entry(for: "/fake/entry-1") != nil)
    #expect(store.entry(for: "/fake/another-cold") != nil)
}

@Test func historyStore_frecencyScoreMath() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let day: TimeInterval = 86_400

    func score(_ count: Int, _ lastUsed: TimeInterval) -> Double {
        HistoryStore.score(launchCount: count, lastLaunchedAt: now.addingTimeInterval(-lastUsed), now: now)
    }

    // Frequency axis: 10 launches today beats 1 launch today
    #expect(score(10, 0) > score(1, 0))
    // Recency axis: 5 launches today beats 5 launches 30 days ago
    #expect(score(5, 0) > score(5, 30 * day))
    // Exact formula: 1 launch right now → 1/(0+2) = 0.5
    #expect(abs(score(1, 0) - 0.5) < 0.0001)
    // Decay: 10 uses a month ago ≈ 0.31 — comparable to 1 use today (0.5)
    #expect(abs(score(10, 30 * day) - 10.0 / 32.0) < 0.0001)
}

@Test @MainActor func homeScreen_historyFirst_noFileDump() {
    let opened = makeTempFile("opened-notes.md")
    let untouched = makeTempFile("untitled.md")
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("hist_\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: opened)
        try? FileManager.default.removeItem(at: untouched)
        try? FileManager.default.removeItem(at: storeURL)
    }

    let store = HistoryStore(fileURL: storeURL)
    store.record(path: opened.path, now: Date())

    let state = ScanState(history: store)
    state.injectResults([
        SearchResult(name: "untitled.md", path: untouched, kind: .file, size: nil, modificationDate: nil),
        SearchResult(name: "opened-notes.md", path: opened, kind: .file, size: nil, modificationDate: nil),
        SearchResult(name: "Zebra.app", path: URL(fileURLWithPath: "/Applications/Zebra.app"), kind: .app, size: nil, modificationDate: nil),
        SearchResult(name: "Alpha.app", path: URL(fileURLWithPath: "/Applications/Alpha.app"), kind: .app, size: nil, modificationDate: nil),
    ])
    state.query = ""

    let visible = state.visibleResults
    // The opened file comes first (only history entry), then apps alphabetically.
    // The untouched .md file must NOT appear — no more alphabetical file dump.
    #expect(visible.first?.name == "opened-notes.md")
    #expect(visible.contains { $0.name == "Alpha.app" })
    #expect(visible.contains { $0.name == "Zebra.app" })
    #expect(!visible.contains { $0.name == "untitled.md" })
    #expect(visible.count <= 15)
}

@Test @MainActor func homeScreen_coldStartBackfillsWithAppsOnly() {
    let store = HistoryStore(fileURL: URL(fileURLWithPath: "/dev/null"))
    let state = ScanState(history: store)
    let apps = (0..<20).map {
        SearchResult(name: String(format: "app%02d", $0),
                     path: URL(fileURLWithPath: "/Applications/app\($0).app"),
                     kind: .app, size: nil, modificationDate: nil)
    }
    state.injectResults(apps)
    state.query = ""

    let visible = state.visibleResults
    #expect(visible.count == 15, "home screen capped at 15")
    #expect(visible.allSatisfy { $0.kind == .app })
}

@Test @MainActor func ranking_frecencyBoostReordersWithinTier() {
    let hot = makeTempFile("terracotta")
    let cold = makeTempFile("teapot")
    let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("hist_\(UUID().uuidString).json")
    defer {
        try? FileManager.default.removeItem(at: hot)
        try? FileManager.default.removeItem(at: cold)
        try? FileManager.default.removeItem(at: storeURL)
    }

    let store = HistoryStore(fileURL: storeURL)
    store.record(path: hot.path, now: Date()) // score 0.5 → boost 1.5x

    let state = ScanState(history: store)
    state.injectResults([
        SearchResult(name: "teapot", path: cold, kind: .file, size: nil, modificationDate: nil),
        SearchResult(name: "terracotta", path: hot, kind: .file, size: nil, modificationDate: nil),
    ])
    state.query = "te" // both prefix matches; without history, "teapot" wins (shorter name)

    let visible = state.visibleResults
    #expect(visible.first?.name == "terracotta", "frequently used item rises within its tier")
}

@Test @MainActor func ranking_matchQualityStillDominates() {
    let store = HistoryStore(fileURL: URL(fileURLWithPath: "/dev/null"))
    let state = ScanState(history: store)
    let exactApp = SearchResult(name: "terminal", path: URL(fileURLWithPath: "/Applications/terminal.app"), kind: .app, size: nil, modificationDate: nil)
    let containsFile = SearchResult(name: "my terminal notes", path: URL(fileURLWithPath: "/tmp/my terminal notes"), kind: .file, size: nil, modificationDate: nil)

    state.injectResults([containsFile, exactApp])
    state.query = "terminal"

    // Even with a max boost (2x = 10,000), a contains match cannot beat an
    // exact match (1,500,000).
    #expect(state.visibleResults.first?.name == "terminal")
}

@Test @MainActor func ranking_unopenedItemsKeepRelativeOrder() {
    let store = HistoryStore(fileURL: URL(fileURLWithPath: "/dev/null"))
    let state = ScanState(history: store)
    let a = SearchResult(name: "teapot", path: URL(fileURLWithPath: "/tmp/teapot"), kind: .file, size: nil, modificationDate: nil)
    let b = SearchResult(name: "terracotta", path: URL(fileURLWithPath: "/tmp/terracotta"), kind: .file, size: nil, modificationDate: nil)

    state.injectResults([b, a])
    state.query = "te"

    // No history: prefix tier, shorter name first (existing behavior preserved).
    #expect(state.visibleResults.map(\.name) == ["teapot", "terracotta"])
}

// MARK: - UI Themes & Slot Keys (add-ui-themes-and-slot-keys)

@Test func themeRegistry_isCompleteAndValid() {
    #expect(ThemeKind.allCases.count == 8)
    #expect(Set(ThemeKind.allCases.map(\.rawValue)).count == 8)

    let validHex = try! NSRegularExpression(pattern: "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$")
    for kind in ThemeKind.allCases {
        let t = Theme.theme(kind)
        for hex in [t.bgTopHex, t.bgBottomHex, t.borderHex, t.textHex, t.accentHex,
                    t.calculatorAccentHex, t.selectionHex, t.onSelectionHex,
                    t.streakSoftHex, t.streakBrightHex] {
            let range = NSRange(hex.startIndex..., in: hex)
            #expect(validHex.firstMatch(in: hex, range: range) != nil, "\(kind): bad hex \(hex)")
        }
        #expect(t.iconSize > 0)
    }
}

@Test func theme_neonFamilyIsDistinctAndComplete() {
    // The four neon themes share the accent-bar skeleton but differ in palette.
    let neon: [ThemeKind] = [.city, .matrix, .sunset, .ice]
    let themes = neon.map(Theme.theme(_:))
    #expect(Set(themes.map(\.accentHex)).count == neon.count,
            "each neon theme has its own accent")

    for t in themes {
        #expect(!t.usesMaterial)
        #expect(t.selectionKind == .accentBar)
        #expect(t.showsStreak && t.showsFooter && t.showsSlotChips)
        #expect(t.queryIsMono)
    }

    // Spot-check: Acid Matrix is black/acid green, Synthwave is pink on indigo.
    let matrix = Theme.theme(.matrix)
    #expect(matrix.accentHex == "#4ADE80" && matrix.bgTopHex == "#050805")
    let sunset = Theme.theme(.sunset)
    #expect(sunset.accentHex == "#FF2E88" && sunset.bgTopHex == "#12081F")
}

@Test func config_removedThemeNamesFallBackGracefully() throws {
    // A config saved with a since-removed theme id decodes to the default
    // theme instead of failing the whole file.
    let json = Data("{\"themeID\":\"cyberpunk\",\"cyberVariant\":\"ice\"}".utf8)
    let decoded = try JSONDecoder().decode(Config.self, from: json)
    #expect(decoded.themeID == nil)
    #expect(decoded.resolvedTheme == .carbonSolid)
}

@Test func theme_carbonSolidMatchesMock() {
    let t = Theme.theme(.carbonSolid)
    #expect(!t.usesMaterial)
    #expect(t.selectionKind == .accentFill)
    #expect(t.accentHex == "#7DD3FC")
    #expect(t.showsFooter && t.showsSlotChips)
    #expect(!t.showsSearchIcon)
}

@Test func theme_classicPreservesOriginalLook() {
    let t = Theme.theme(.classic)
    #expect(t.usesMaterial)
    #expect(t.cornerRadius == 18)
    #expect(t.queryFontSize == 24 && t.nameFontSize == 16)
    #expect(t.showsSearchIcon && !t.showsFooter && !t.showsSlotChips)
    #expect(t.selectionKind == .classicFill)
}

@Test func config_themeRoundtripAndBackwardCompat() throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    // Old config without themeID decodes; defaults to Carbon Solid.
    let legacyJSON = Data("{\"selectedScopes\":[],\"customScopes\":[]}".utf8)
    let legacy = try decoder.decode(Config.self, from: legacyJSON)
    #expect(legacy.themeID == nil)
    #expect(legacy.resolvedTheme == .carbonSolid)

    // Theme round-trips through JSON.
    var config = Config()
    config.themeID = .paper
    let data = try encoder.encode(config)
    let decoded = try decoder.decode(Config.self, from: data)
    #expect(decoded.themeID == .paper)
    #expect(decoded.resolvedTheme == .paper)
}

@Test func config_defaultsToEmptyScanFolders() throws {
    let config = Config()
    #expect(config.scanFolders.isEmpty, "Apps-only default: no folders selected")
    #expect(config.availableScanFolders.isEmpty)
}

@Test func config_legacySelectedScopesMigrateToScanFolders() throws {
    let decoder = JSONDecoder()
    // Old config with the big three selected (pre-ScanFolder format).
    let legacyJSON = Data(#"{"selectedScopes":["Downloads","Desktop"],"customScopes":[]}"#.utf8)
    let legacy = try decoder.decode(Config.self, from: legacyJSON)
    #expect(legacy.scanFolders.count == 2)
    #expect(legacy.scanFolders.contains { $0.name == "Downloads" })
    #expect(legacy.scanFolders.contains { $0.name == "Desktop" })
    // Defaults applied to migrated entries.
    #expect(legacy.scanFolders.allSatisfy { $0.depth == 3 && $0.fileCap == 5000 })
}

@Test func config_scanFolderRoundTrip() throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    let folder = ScanFolder(name: "Notes", path: URL(fileURLWithPath: "/tmp/notes"), depth: 2, fileCap: 100)
    var config = Config()
    config.scanFolders = [folder]
    let data = try encoder.encode(config)
    let decoded = try decoder.decode(Config.self, from: data)
    #expect(decoded.scanFolders.count == 1)
    #expect(decoded.scanFolders[0].name == "Notes")
    #expect(decoded.scanFolders[0].depth == 2)
    #expect(decoded.scanFolders[0].fileCap == 100)
}

@Test func folderScanner_respectsDepthCap() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let lvl1 = tempDir.appendingPathComponent("a")
    let lvl2 = lvl1.appendingPathComponent("b")
    let lvl3 = lvl2.appendingPathComponent("c")
    try FileManager.default.createDirectory(at: lvl3, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: lvl1.appendingPathComponent("f1.txt").path, contents: Data())
    FileManager.default.createFile(atPath: lvl2.appendingPathComponent("f2.txt").path, contents: Data())
    FileManager.default.createFile(atPath: lvl3.appendingPathComponent("f3.txt").path, contents: Data())
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Depth 1 = the root folder's own direct files + subdir names only
    // (root is level 1; a/ is level 2, so f1.txt inside it is excluded).
    let depth1 = FolderScanner().scan(path: tempDir.path, depth: 1)
    #expect(depth1.contains { $0.name == "a" })
    #expect(!depth1.contains { $0.name == "f1.txt" })

    // Depth 2 reaches a/f1.txt but not b/f2.txt.
    let depth2 = FolderScanner().scan(path: tempDir.path, depth: 2)
    #expect(depth2.contains { $0.name == "f1.txt" })
    #expect(!depth2.contains { $0.name == "f2.txt" })

    // Depth 4 reaches a/b/c/f3.txt.
    let depth4 = FolderScanner().scan(path: tempDir.path, depth: 4)
    #expect(depth4.contains { $0.name == "f3.txt" })
}

@Test func folderScanner_respectsFileCap() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    for i in 0..<10 {
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent("f\(i).txt").path, contents: Data())
    }
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let capped = FolderScanner().scan(path: tempDir.path, fileCap: 3)
    let files = capped.filter { $0.kind == .file }
    #expect(files.count == 3)
}

@Test func appScanner_includesCoreServicesApps() {
    let apps = AppScanner().scan()
    #expect(apps.contains { $0.name == "Finder" },
            "Finder lives in CoreServices, outside the standard app folders")
}

@Test func pixelAmbient_effectMapping() {
    // Rain family + snow; static themes stay static.
    #expect(PixelAmbientView.effect(for: .matrix) == .rain)   // Acid Matrix rains
    #expect(PixelAmbientView.effect(for: .ice) == .snow)      // Ice Circuit snows
    #expect(PixelAmbientView.effect(for: .sunset) == .miami)  // Synthwave Sunset gets Miami Nights
    #expect(PixelAmbientView.effect(for: .city) == .city)     // Neon City gets the skyline
    #expect(PixelAmbientView.effect(for: .classic) == nil)
    #expect(PixelAmbientView.effect(for: .carbonSolid) == nil)
    #expect(PixelAmbientView.effect(for: .schematic) == nil)
    #expect(PixelAmbientView.effect(for: .paper) == nil)
}
