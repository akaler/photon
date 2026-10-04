import Foundation

public class AppScanner {
    // System apps + user-installed apps + user's own Applications folder
    public let locations = [
        "/System/Applications",
        "/Applications",
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/Applications",
    ]

    /// Core-services apps that live outside the standard app folders and are
    /// therefore missed by the directory scan. Finder is the obvious one —
    /// every Mac has it at this exact path.
    public let explicitApps = [
        "/System/Library/CoreServices/Finder.app",
    ]

    public init() {}

    /// Scan system apps plus any additional scope directories.
    /// - Parameter extraScopes: Additional directories to look for .app bundles
    /// - Parameter showProgress: Print progress to stdout (default: false)
    public func scan(extraScopes: [URL] = [], showProgress: Bool = false) -> [App] {
        var results: [App] = []

        // Core-services apps first (Finder etc.) — always present on macOS.
        for path in explicitApps {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            results.append(App(name: url.deletingPathExtension().lastPathComponent, path: url))
        }

        var allLocations: [String] = locations
        for scope in extraScopes {
            allLocations.append(scope.path)
        }

        for location in allLocations {
            let isSystem = locations.contains(location)
            if showProgress {
                print("Scanning \(isSystem ? "[system]" : "[scope]") \(location)...")
            }
            guard FileManager.default.fileExists(atPath: location) else {
                if showProgress { print("  folder not found, skipping") }
                continue
            }

            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: location)
                if showProgress {
                    print("  found \(contents.count) items, extracting .app bundles")
                }

                for name in contents {
                    collectApp(from: name, location: location) { results.append($0) }
                }

                // One-level recursion so apps in subfolders are picked up,
                // e.g. /System/Applications/Utilities/Terminal.app
                for name in contents {
                    let subPath = "\(location)/\(name)"
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: subPath, isDirectory: &isDir),
                          isDir.boolValue, !name.hasSuffix(".app") else { continue }
                    if let nested = try? FileManager.default.contentsOfDirectory(atPath: subPath) {
                        for nestedName in nested {
                            collectApp(from: nestedName, location: subPath) { results.append($0) }
                        }
                    }
                }
            } catch {
                if showProgress { print("  error: \(error)") }
            }
        }

        return results
    }

    private func collectApp(from name: String, location: String, append: (App) -> Void) {
        guard name.hasSuffix(".app") else { return }

        let fullRelativePath = "\(location)/\(name)"
        let bundleURL = URL(fileURLWithPath: fullRelativePath)
        let nameWithoutExt = bundleURL.deletingPathExtension().lastPathComponent

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullRelativePath, isDirectory: &isDir),
              isDir.boolValue else { return }

        append(App(name: nameWithoutExt, path: bundleURL))
    }
}
