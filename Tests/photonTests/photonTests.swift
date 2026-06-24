import Testing
@testable import PhotonCore
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

    #expect(results.count == 3, "Expected 3 files, got \(results.count)")
    #expect(results.contains { $0.name == file1 })
    #expect(results.contains { $0.name == file2 })
    #expect(results.contains { $0.name == file3 })
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
