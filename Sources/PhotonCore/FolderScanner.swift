import Foundation

public class FolderScanner {

    public init() {}

    /// Scan a directory recursively and return IndexedFile for every file and subdirectory found.
    /// - Parameters:
    ///   - path: Directory path to scan
    ///   - showProgress: Print progress to stdout (default: false)
    /// - Returns: Array of indexed files and directories
    public func scan(path: String, depth: Int = Int.max, fileCap: Int = Int.max, showProgress: Bool = false) -> [IndexedFile] {
        let url = URL(fileURLWithPath: path)
        return scan(url: url, depth: depth, fileCap: fileCap, showProgress: showProgress)
    }

    public func scan(url: URL, depth: Int = Int.max, fileCap: Int = Int.max, showProgress: Bool = false) -> [IndexedFile] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if showProgress { print("  ⚠ directory not found: \(url.path)") }
            return []
        }

        if showProgress {
            print("  scanning \(url.path)...")
        }

        var counter = FileCounter()
        let scanned = scanRecursive(at: url, depth: depth, fileCap: fileCap, fileCount: &counter, currentLevel: 1, showProgress: showProgress, isRoot: true)
        if showProgress {
            print("  \(scanned.count) entries (capped at \(fileCap) files, depth \(depth))")
        }
        return scanned
    }

    /// Mutable counter so the file cap is shared across the whole recursion.
    private struct FileCounter {
        var count = 0
    }

    /// Recursively enumerate files and subdirectories.
    /// Each directory is listed before its children so it can match queries first.
    /// Stops descending past `depth` and stops collecting files once `fileCount`
    /// reaches `fileCap` (directories still surface for navigation).
    private func scanRecursive(at url: URL, depth: Int, fileCap: Int, fileCount: inout FileCounter, currentLevel: Int, showProgress: Bool, isRoot: Bool) -> [IndexedFile] {
        var results: [IndexedFile] = []

        guard currentLevel <= depth else { return results }

        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: options) else {
            return results
        }

        for childURL in contents {
            // Skip anything inside .app bundles
            guard !childURL.pathComponents.contains(where: { $0.hasSuffix(".app") }) else { continue }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: childURL.path, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                // Add the subdirectory itself (so it can match queries like "screenshots")
                if let dir = try? collectDirectory(at: childURL) {
                    results.append(dir)
                }
                // Recurse into it (respecting depth + shared file cap).
                // Once the cap is reached we stop descending: no more files can
                // be collected, so further I/O is wasted.
                if fileCount.count < fileCap {
                    results.append(contentsOf: scanRecursive(at: childURL, depth: depth, fileCap: fileCap, fileCount: &fileCount, currentLevel: currentLevel + 1, showProgress: showProgress, isRoot: false))
                }
            } else {
                guard fileCount.count < fileCap else { continue }
                if let file = try? collectFile(at: childURL) {
                    results.append(file)
                    fileCount.count += 1
                }
            }
        }

        return results
    }

    private func collectFile(at url: URL) throws -> IndexedFile {
        let resources = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])

        let ext = url.pathExtension.isEmpty ? nil : url.pathExtension
        let size = (resources.fileSize ?? 0)
        let modDate = resources.contentModificationDate ?? Date()
        let name = url.lastPathComponent

        return IndexedFile(
            name: name,
            path: url,
            size: Int64(size),
            fileExtension: ext,
            modificationDate: modDate
        )
    }

    private func collectDirectory(at url: URL) throws -> IndexedFile {
        let resources = try url.resourceValues(forKeys: [.contentModificationDateKey])
        let modDate = resources.contentModificationDate ?? Date()
        let name = url.lastPathComponent

        return IndexedFile(
            name: name,
            path: url,
            size: 0,
            fileExtension: nil,
            modificationDate: modDate,
            kind: .directory
        )
    }
}
