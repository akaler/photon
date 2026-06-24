import Foundation
import PhotonCore

func main() {
    print("╔═══════════════════════════════╗")
    print("║         ⚡ Photon CLI          ║")
    print("╚═══════════════════════════════╝")
    print()

    // Start with default: Desktop, Documents, Downloads all preselected
    var config = Config.load()
    config.selectedScopes = Scope.allCases

    // Present scope selection menu
    print("Select scopes to index:")
    print()

    for (index, scope) in Scope.allCases.enumerated() {
        let star = config.selectedScopes.contains(scope) ? "✓" : " "
        print("  [\(star)] \(index + 1). \(scope.label) (\(scope.path.path))")
    }

    print()
    print("  [c] Custom path")
    print("  [a] All scopes")
    print("  [u] Untoggle currently selected")
    print()
    print("Enter choice (or press Enter to continue): ", terminator: "")

    if let input = readLine() {
        let choice = input.lowercased().trimmingCharacters(in: .whitespaces)

        switch choice {
        case "1":
            toggleScope(scope: .downloads, config: &config)
        case "2":
            toggleScope(scope: .documents, config: &config)
        case "3":
            toggleScope(scope: .desktop, config: &config)
        case "c", "custom":
            addCustomScope(config: &config)
        case "a", "all":
            config.selectedScopes = Scope.allCases
        case "u", "untoggle":
            showSelectedScopes(config: config)
        default:
            break
        }
    }

    // Save config
    config.save()

    // Build final list of directories to scan
    let allPaths = config.allScopes

    print()
    print()
    print("─── Scan Configuration ───")
    print("System apps:    /System/Applications")
    print()

    if !allPaths.isEmpty {
        print("User scopes:")
        for path in allPaths {
            let available = FileManager.default.fileExists(atPath: path.path) ? "✓" : "⚠"
            print("  [\(available)] \(path.path)")
        }
    } else {
        print("User scopes:    (none selected)")
    }
    print()

    // Run both scans
    print("─── Scanning Apps ───")
    let apps = AppScanner().scan(extraScopes: allPaths, showProgress: true)
    print("Found \(apps.count) applications")

    print()
    print()
    print("─── Scanning Folders ───")
    let folderScanner = FolderScanner()
    var allFiles: [IndexedFile] = []

    for path in allPaths {
        let files = folderScanner.scan(url: path, showProgress: true)
        allFiles.append(contentsOf: files)
    }

    if allFiles.isEmpty {
        print("No files found in selected scopes.")
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

func toggleScope(scope: Scope, config: inout Config) {
    if config.selectedScopes.contains(scope) {
        config.selectedScopes.removeAll { $0 == scope }
        print("  ✗ Deselected \(scope.label)")
    } else {
        config.selectedScopes.append(scope)
        print("  ✓ Selected \(scope.label)")
        print("    → \(scope.path.path)")
    }
}

func addCustomScope(config: inout Config) {
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
    let custom = CustomScope(name: name, path: url)
    config.customScopes.append(custom)
    print("  ✓ Added custom scope: \(custom.name) → \(custom.path.path)")
}

func showSelectedScopes(config: Config) {
    print()
    print("Selected scopes:")
    for scope in config.selectedScopes {
        print("  • \(scope.label) (\(scope.path.path))")
    }
    for scope in config.customScopes {
        print("  • \(scope.name) (\(scope.path.path))")
    }
}

main()
