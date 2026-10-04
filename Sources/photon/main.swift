import Foundation
import PhotonCore

func main() {
    print("╔═══════════════════════════════╗")
    print("║         ⚡ Photon CLI          ║")
    print("╚═══════════════════════════════╝")
    print()

    // Apps are always indexed. Folders are opt-in; start from current config.
    var config = Config.load()

    // Present scope selection menu
    print("Select folders to index for file search (apps are always indexed):")
    print()

    let standard = Scope.allCases
    for (index, scope) in standard.enumerated() {
        let checked = config.scanFolders.contains { $0.path == scope.path } ? "✓" : " "
        print("  [\(checked)] \(index + 1). \(scope.label) (\(scope.path.path))")
    }

    print()
    print("  [c] Custom path")
    print("  [a] All standard folders")
    print("  [u] Untoggle currently selected")
    print()
    print("Enter choice (or press Enter to continue): ", terminator: "")

    if let input = readLine() {
        let choice = input.lowercased().trimmingCharacters(in: .whitespaces)

        switch choice {
        case "1":
            toggleFolder(scope: .downloads, config: &config)
        case "2":
            toggleFolder(scope: .documents, config: &config)
        case "3":
            toggleFolder(scope: .desktop, config: &config)
        case "c", "custom":
            addCustomFolder(config: &config)
        case "a", "all":
            for scope in Scope.allCases {
                if !config.scanFolders.contains(where: { $0.path == scope.path }) {
                    config.scanFolders.append(ScanFolder(name: scope.label, path: scope.path))
                }
            }
        case "u", "untoggle":
            showSelectedFolders(config: config)
        default:
            break
        }
    }

    // Save config
    config.save()

    // Build final list of directories to scan
    let folders = config.availableScanFolders

    print()
    print()
    print("─── Scan Configuration ───")
    print("System apps:    /System/Applications")
    print()

    if !folders.isEmpty {
        print("User folders:")
        for folder in folders {
            let available = FileManager.default.fileExists(atPath: folder.path.path) ? "✓" : "⚠"
            print("  [\(available)] \(folder.name)  (depth \(folder.depth), cap \(folder.fileCap))  \(folder.path.path)")
        }
    } else {
        print("User folders:    (none — apps only)")
    }
    print()

    // Run both scans
    print("─── Scanning Apps ───")
    let apps = AppScanner().scan()
    print("Found \(apps.count) applications")

    print()
    print()
    print("─── Scanning Folders ───")
    let folderScanner = FolderScanner()
    var allFiles: [IndexedFile] = []

    for folder in folders {
        let files = folderScanner.scan(url: folder.path, depth: folder.depth, fileCap: folder.fileCap, showProgress: true)
        allFiles.append(contentsOf: files)
    }

    if allFiles.isEmpty {
        print("No files found in selected folders.")
    } else {
        print("Found \(allFiles.count) files:\n")
        let sorted = allFiles.sorted { $0.name.lowercased() < $1.name.lowercased() }
        for file in sorted {
            print("  • \(file.name)  (\(file.displaySize))  \(file.path.path)")
        }
    }

    print()
    print("\nDone! Scanned \(apps.count) apps, \(allFiles.count) files.")
}

// MARK: - Helpers

func toggleFolder(scope: Scope, config: inout Config) {
    if let idx = config.scanFolders.firstIndex(where: { $0.path == scope.path }) {
        config.scanFolders.remove(at: idx)
        print("  ✗ Removed \(scope.label)")
    } else {
        config.scanFolders.append(ScanFolder(name: scope.label, path: scope.path))
        print("  ✓ Added \(scope.label)")
        print("    → \(scope.path.path)")
    }
}

func addCustomFolder(config: inout Config) {
    print()
    print("Enter path to add: ", terminator: "")
    guard let pathInput = readLine() else { return }
    let trimmed = pathInput.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }

    let url = URL(fileURLWithPath: trimmed)
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("  ✗ Path does not exist: \(url.path)")
        return
    }

    let name = url.lastPathComponent
    config.scanFolders.append(ScanFolder(name: name, path: url))
    print("  ✓ Added folder: \(name) → \(url.path)")
}

func showSelectedFolders(config: Config) {
    print()
    print("Selected folders:")
    for folder in config.scanFolders {
        print("  • \(folder.name) (\(folder.path.path))  depth \(folder.depth), cap \(folder.fileCap)")
    }
}

main()
