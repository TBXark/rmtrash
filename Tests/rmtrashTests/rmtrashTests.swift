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

struct StaticAnswer: Question {
    let value: Bool
    func ask(_ message: String) -> Bool {
        return value
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
}

extension RmTrashTests {

    func makeTrash(
        interactiveMode: Trash.Config.InteractiveMode = .never,
        force: Bool = true,
        recursive: Bool = false,
        emptyDirs: Bool = false,
        preserveRoot: Bool = true,
        oneFileSystem: Bool = false,
        verbose: Bool = false,
        fileManager: FileManagerType? = nil,
        question: Question? = nil
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
            question: question ?? StaticAnswer(value: true),
            fileManager: fileManager ?? FileManager.default
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
}
