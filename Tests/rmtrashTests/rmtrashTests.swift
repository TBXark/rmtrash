import XCTest
@testable import rmtrash

enum FileNode: Equatable, Comparable {

    case file(name: String)
    case directory(name: String, sub: [FileNode])

    var name: String {
        switch self {
        case .file(let name): return name
        case .directory(let name, _): return name
        }
    }

    var isDirectory: Bool {
        switch self {
        case .file: return false
        case .directory: return true
        }
    }

    static func < (lhs: FileNode, rhs: FileNode) -> Bool {
        return lhs.name < rhs.name
    }

    static func ==(lhs: FileNode, rhs: FileNode) -> Bool {
        switch (lhs, rhs) {
        case (.file(let l), .file(let r)):
            return l == r
        case (.directory(let l, let ls), .directory(let r, let rs)):
            guard l == r else { return false }
            let lss = ls.sorted()
            let rss = rs.sorted()
            if lss.count != rss.count { return false }
            return zip(lss, rss).allSatisfy(==)
        default:
            return false
        }
    }
}

extension Array where Element == FileNode {
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.count == rhs.count else { return false }
        let lss = lhs.sorted()
        let rss = rhs.sorted()
        return zip(lss, rss).allSatisfy(==)
    }
}

struct StaticAnswer: Question {
    let value: Bool
    func ask(_ message: String) -> Bool {
        return value
    }
}

extension FileManager {
    func currentFileStructure(at url: URL) -> FileNode? {
        guard let attr = try? attributesOfItem(atPath: url.path),
              let type = attr[.type] as? FileAttributeType else {
            return nil
        }
        if type == .typeDirectory {
            var sub = [FileNode]()
            guard let paths = try? contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
                return nil
            }
            for path in paths {
                if let node = currentFileStructure(at: url.appendingPathComponent(path.lastPathComponent)) {
                    sub.append(node)
                }
            }
            return FileNode.directory(name: url.lastPathComponent, sub: sub)
        }
        return FileNode.file(name: url.lastPathComponent)
    }

    func createFileStructure(node: FileNode, at url: URL) {
        switch node {
        case .file(let name):
            createFile(atPath: url.appendingPathComponent(name).path, contents: nil, attributes: nil)
        case .directory(let name, let sub):
            let dirUrl = url.appendingPathComponent(name)
            try? createDirectory(at: dirUrl, withIntermediateDirectories: true, attributes: nil)
            for node in sub {
                createFileStructure(node: node, at: dirUrl)
            }
        }
    }

    func createFileStructure(nodes: [FileNode], at url: URL) {
        for node in nodes {
            createFileStructure(node: node, at: url)
        }
    }

    static func createTempDirectory() -> (fileManager: FileManager, url: URL) {
        let fileManager = FileManager()
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        fileManager.changeCurrentDirectoryPath(tempDir.path)
        return (fileManager, tempDir)
    }
}

final class RmTrashTests: XCTestCase {

    func testForceConfig() {

        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .file(name: "test.txt"),
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt")
            ])
        ]
        fileManager.createFileStructure(nodes: mockFiles, at: url)

        let trash = makeTrash(force: true, fileManager: fileManager)
        XCTAssertTrue(trash.removeMultiple(paths: ["./test.txt"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt")
            ])
        ])
    }

    func testRecursiveConfig() {

        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt"),
                .directory(name: "subdir", sub: [
                    .file(name: "file2.txt")
                ])
            ])
        ]

        fileManager.createFileStructure(nodes: mockFiles, at: url)

        // Test non-recursive config
        let nonRecursiveTrash = makeTrash(fileManager: fileManager)
        XCTAssertFalse(nonRecursiveTrash.removeMultiple(paths: ["./dir1"]))
        assertFileStructure(fileManager, at: url, expectedFiles: mockFiles)

        // Test recursive config
        let recursiveTrash = makeTrash(recursive: true, fileManager: fileManager)
        XCTAssertTrue(recursiveTrash.removeMultiple(paths: ["./dir1"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [])
    }

    func testEmptyDirsConfig() {

        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .directory(name: "emptyDir", sub: []),
            .directory(name: "nonEmptyDir", sub: [
                .file(name: "file.txt")
            ])
        ]

        fileManager.createFileStructure(nodes: mockFiles, at: url)

        let trash = makeTrash(emptyDirs: true, fileManager: fileManager)
        XCTAssertTrue(trash.removeMultiple(paths: ["./emptyDir"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [
            .directory(name: "nonEmptyDir", sub: [
                .file(name: "file.txt")
            ])
        ])
        XCTAssertFalse(trash.removeMultiple(paths: ["./nonEmptyDir"]))
    }

    func testInteractiveModeOnce() {

        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .file(name: "test1.txt"),
            .directory(name: "dir1", sub: [])
        ]

        fileManager.createFileStructure(nodes: mockFiles, at: url)

        // Test with no answer
        let noTrash = makeTrash(
            interactiveMode: .once,
            force: false,
            recursive: true,
            fileManager: fileManager,
            question: StaticAnswer(value: false)
        )
        XCTAssertTrue(noTrash.removeMultiple(paths: ["./test1.txt", "./dir1"]))
        assertFileStructure(fileManager, at: url, expectedFiles: mockFiles)

        // Test with yes answer
        let yesTrash = makeTrash(
            interactiveMode: .once,
            force: false,
            recursive: true,
            fileManager: fileManager,
            question: StaticAnswer(value: true)
        )
        XCTAssertTrue(yesTrash.removeMultiple(paths: ["./test1.txt", "./dir1"]))
        XCTAssertTrue(fileManager.isEmptyDirectory(url))
        assertFileStructure(fileManager, at: url, expectedFiles: [])
    }

    func testInteractiveModeAlways() {

        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .file(name: "test1.txt"),
            .file(name: "test2.txt")
        ]

        fileManager.createFileStructure(nodes: mockFiles, at: url)

        // Test with no answer
        let noTrash = makeTrash(
            interactiveMode: .always,
            force: false,
            fileManager: fileManager,
            question: StaticAnswer(value: false)
        )
        XCTAssertTrue(noTrash.removeMultiple(paths: ["./test1.txt", "./test2.txt"]))
        assertFileStructure(fileManager, at: url, expectedFiles: mockFiles)

        // Test with yes answer
        let yesTrash = makeTrash(
            interactiveMode: .always,
            force: false,
            fileManager: fileManager,
            question: StaticAnswer(value: true)
        )
        XCTAssertTrue(yesTrash.removeMultiple(paths: ["./test1.txt", "./test2.txt"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [])
    }

    func testSubDir() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let initialFiles: [FileNode] = [
            .file(name: "test1.txt"),
            .file(name: "test2.txt"),
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt"),
                .file(name: "file2.txt"),
                .directory(name: "subdir", sub: [
                    .file(name: "deep.txt")
                ])
            ])
        ]

        fileManager.createFileStructure(nodes: initialFiles, at: url)
        let trash = makeTrash(force: true, fileManager: fileManager)

        XCTAssertTrue(trash.removeMultiple(paths: ["./dir1/file1.txt"]))
        fileManager.changeCurrentDirectoryPath("dir1")

        XCTAssertTrue(trash.removeMultiple(paths: ["./file2.txt"]))
        assertFileStructure(fileManager, at: url.appendingPathComponent("dir1"), expectedFiles: [
            .directory(name: "subdir", sub: [
                .file(name: "deep.txt")
            ])
        ])
    }

    func testFileListStateAfterDeletion() {

        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let initialFiles: [FileNode] = [
            .file(name: "test1.txt"),
            .file(name: "test2.txt"),
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt"),
                .file(name: "file2.txt"),
                .directory(name: "subdir", sub: [
                    .file(name: "deep.txt")
                ])
            ])
        ]

        fileManager.createFileStructure(nodes: initialFiles, at: url)

        let trash = makeTrash(recursive: true, emptyDirs: true, fileManager: fileManager)

        // Test single file deletion
        XCTAssertTrue(trash.removeMultiple(paths: ["./test1.txt"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [
            .file(name: "test2.txt"),
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt"),
                .file(name: "file2.txt"),
                .directory(name: "subdir", sub: [
                    .file(name: "deep.txt")
                ])
            ])
        ])

        // Test directory deletion
        XCTAssertTrue(trash.removeMultiple(paths: ["./dir1"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [
            .file(name: "test2.txt")
        ])

        // Test remaining file deletion
        XCTAssertTrue(trash.removeMultiple(paths: ["./test2.txt"]))
        assertFileStructure(fileManager, at: url, expectedFiles: [])
    }

    func testRemoveSymlink() {

        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let trash = makeTrash(force: false, recursive: true, emptyDirs: true, fileManager: fileManager)

        let file = url.appending(path: "no_such_file")
        let link = url.appending(path: "sym.link")

        XCTAssertNil(fileManager.fileType(file))
        XCTAssertNil(fileManager.fileType(link))
        XCTAssertNoThrow(try fileManager.createSymbolicLink(at: link, withDestinationURL: file))

        fileManager.subpaths(atPath: ".") { link in
            XCTAssertEqual(link, "./sym.link")
            return true
        }

        if let subs = try? fileManager.contentsOfDirectory(atPath: url.relativePath), let sub = subs.first {
            XCTAssertEqual(sub, "sym.link")
        }

        XCTAssertEqual(fileManager.fileType(link), .typeSymbolicLink)
        XCTAssertTrue(trash.removeMultiple(paths: ["sym.link"]))
        XCTAssertNil(fileManager.fileType(link))
    }
    
    func testRemoveHardLink() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        let trash = makeTrash(force: false, recursive: true, fileManager: fileManager)
        
        // Create original file
        let originalFile = url.appendingPathComponent("original.txt")
        let testContent = "test content".data(using: .utf8)!
        fileManager.createFile(atPath: originalFile.path, contents: testContent, attributes: nil)
        
        // Create hard link
        let hardLink = url.appendingPathComponent("hardlink.txt")
        XCTAssertNoThrow(try fileManager.linkItem(at: originalFile, to: hardLink))
        
        // Both should exist and be regular files
        XCTAssertEqual(fileManager.fileType(originalFile), .typeRegular)
        XCTAssertEqual(fileManager.fileType(hardLink), .typeRegular)
        
        // Both should have the same content
        XCTAssertEqual(try? Data(contentsOf: originalFile), testContent)
        XCTAssertEqual(try? Data(contentsOf: hardLink), testContent)
        
        // Remove the hard link (should behave like rm - only remove one reference)
        XCTAssertTrue(trash.removeMultiple(paths: ["hardlink.txt"]))
        
        // Hard link should be gone, but original file should still exist
        XCTAssertNil(fileManager.fileType(hardLink))
        XCTAssertEqual(fileManager.fileType(originalFile), .typeRegular)
        XCTAssertEqual(try? Data(contentsOf: originalFile), testContent)
    }
    
    func testRemoveSymlinkToExistingFile() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        let trash = makeTrash(force: false, recursive: true, fileManager: fileManager)
        
        // Create target file
        let targetFile = url.appendingPathComponent("target.txt")
        let testContent = "target content".data(using: .utf8)!
        fileManager.createFile(atPath: targetFile.path, contents: testContent, attributes: nil)
        
        // Create symbolic link to existing file
        let symlink = url.appendingPathComponent("symlink.txt")
        XCTAssertNoThrow(try fileManager.createSymbolicLink(at: symlink, withDestinationURL: targetFile))
        
        // Verify types
        XCTAssertEqual(fileManager.fileType(targetFile), .typeRegular)
        XCTAssertEqual(fileManager.fileType(symlink), .typeSymbolicLink)
        
        // Remove symbolic link (should behave like rm - only remove the link, not the target)
        XCTAssertTrue(trash.removeMultiple(paths: ["symlink.txt"]))
        
        // Symbolic link should be gone, but target file should still exist
        XCTAssertNil(fileManager.fileType(symlink))
        XCTAssertEqual(fileManager.fileType(targetFile), .typeRegular)
        XCTAssertEqual(try? Data(contentsOf: targetFile), testContent)
    }

    func testMultipleFilesRemoval() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        let mockFiles: [FileNode] = [
            .file(name: "test1.txt"),
            .file(name: "test2.txt"),
            .file(name: "test3.txt"),
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt")
            ]),
            .directory(name: "dir2", sub: [])
        ]
        fileManager.createFileStructure(nodes: mockFiles, at: url)

        // Test removing multiple files together
        let trash = makeTrash(
            force: true,
            recursive: true,
            emptyDirs: true,
            fileManager: fileManager
        )
        XCTAssertTrue(trash.removeMultiple(paths: [
            "./test1.txt",
            "./test2.txt",
            "./dir1",
            "./dir2"
        ]))

        assertFileStructure(fileManager, at: url, expectedFiles: [
            .file(name: "test3.txt")
        ])
    }

    func testNonExistentFiles() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        // Test with force = false
        let trashNoForce = makeTrash(
            force: false,
            fileManager: fileManager
        )
        XCTAssertFalse(trashNoForce.removeMultiple(paths: ["./nonexistent.txt"]))

        // Test with force = true
        let trashForce = makeTrash(
            force: true,
            fileManager: fileManager
        )
        XCTAssertTrue(trashForce.removeMultiple(paths: ["./nonexistent.txt"]))
    }
}

final class FileManagerTests: XCTestCase {

    func testIsRootDir() throws {

        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        XCTAssertTrue(fileManager.isRootDir(URL(fileURLWithPath: "/")))
        XCTAssertFalse(fileManager.isRootDir(url))
    }

    func testIsEmptyDirectory() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        // Empty directory
        XCTAssertTrue(fileManager.isEmptyDirectory(url))

        // Directory with a file
        let fileURL = url.appendingPathComponent("test.txt")
        fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        XCTAssertFalse(fileManager.isEmptyDirectory(url))
    }

    func testFileTypeDetection() {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }

        XCTAssertNil(fileManager.fileType(url.appendingPathComponent("no_file")))

        let fileURL = url.appendingPathComponent("temp.txt")
        fileManager.createFile(atPath: fileURL.path, contents: nil, attributes: nil)
        XCTAssertEqual(fileManager.fileType(fileURL), .typeRegular)
        XCTAssertEqual(fileManager.fileType(url), .typeDirectory)
    }
    
    func testCrossMountPointDetection() throws {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        // Test same volume detection
        let subDir = url.appendingPathComponent("subdir")
        try fileManager.createDirectory(at: subDir, withIntermediateDirectories: true, attributes: nil)
        
        // Files on the same volume should not be cross-mount points
        XCTAssertFalse(try fileManager.isCrossMountPoint(subDir))
        XCTAssertFalse(try fileManager.isCrossMountPoint(url))
        
        // Test with root directory (different volume in most cases)
        let rootURL = URL(fileURLWithPath: "/")
        
        // Get volume info to check if we're actually on different volumes
        let tempVol = try url.resourceValues(forKeys: [.volumeURLKey])
        let rootVol = try rootURL.resourceValues(forKeys: [.volumeURLKey])
        
        // Only test cross-mount if we're actually on different volumes
        if tempVol.volume != rootVol.volume {
            XCTAssertTrue(try fileManager.isCrossMountPoint(rootURL))
        }
    }
    
    func testVolumeInfoExtraction() throws {
        let (fileManager, url) = FileManager.createTempDirectory()
        defer { try? fileManager.removeItem(at: url) }
        
        let resourceValues = try url.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey, .volumeNameKey])
        
        // Basic volume info should be available
        XCTAssertNotNil(resourceValues.volume)
        XCTAssertNotNil(resourceValues.volumeName)
    }
}

func makeTrash(
    interactiveMode: Trash.Config.InteractiveMode = .never,
    force: Bool = true,
    recursive: Bool = false,
    emptyDirs: Bool = false,
    preserveRoot: Bool = true,
    oneFileSystem: Bool = false,
    verbose: Bool = false,
    fileManager: FileManagerType = FileManager.default,
    question: Question =  StaticAnswer(value: true)
) -> Trash {
    let config = Trash.Config(
        interactiveMode: interactiveMode,
        force: force,
        recursive: recursive,
        emptyDirs: emptyDirs,
        preserveRoot: preserveRoot,
        oneFileSystem: oneFileSystem,
        verbose: verbose
    )
    return Trash(
        config: config,
        question: question,
        fileManager: fileManager
    )
}

func assertFileStructure(_ fileManager: FileManager, at url: URL, expectedFiles: [FileNode], file: StaticString = #file, line: UInt = #line) {
    guard let node = fileManager.currentFileStructure(at: url) else {
        XCTFail("Failed to read file structure at \(url)", file: file, line: line)
        return
    }
    switch node {
    case .directory(_, let sub):
        XCTAssertTrue(sub == expectedFiles, file: file, line: line)
    case .file:
        XCTFail("Expected directory, found file", file: file, line: line)
    }
}
