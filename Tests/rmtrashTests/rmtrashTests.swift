import XCTest
@testable import rmtrash

enum FileMock: Equatable {
    case file(name: String)
    case directory(name: String, sub: [FileMock])

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
}

class FileManagerMock: FileManagerType {
    private var root: [FileMock]

    init(root: [FileMock]) {
        self.root = root
    }

    private func findFile(components: [String], in files: [FileMock]) -> FileMock? {
        // Special case for root directory
        if components.isEmpty || (components.count == 1 && components[0].isEmpty) {
            return .directory(name: "", sub: files)
        }

        guard let first = components.first else { return nil }
        for file in files {
            if file.name == first {
                if components.count == 1 {
                    return file
                } else {
                    switch file {
                    case .directory(_, let sub):
                        return findFile(components: Array(components.dropFirst()), in: sub)
                    default:
                        return nil
                    }
                }
            }
        }
        return nil
    }

    private func removeFile(components: [String], from files: inout [FileMock]) -> Bool {
        guard let first = components.first else { return false }

        if components.count == 1 {
            // Remove the file directly from current directory
            if let index = files.firstIndex(where: { $0.name == first }) {
                files.remove(at: index)
                return true
            }
            return false
        }

        // Navigate to subdirectory
        for i in 0..<files.count {
            if files[i].name == first {
                if case .directory(let name, var sub) = files[i] {
                    if removeFile(components: Array(components.dropFirst()), from: &sub) {
                        files[i] = .directory(name: name, sub: sub)
                        return true
                    }
                }
            }
        }
        return false
    }

    func trashItem(at url: URL) throws {
        let components = url.pathComponents.filter { $0 != "/" }
        if components.isEmpty {
            root = []
        } else if !removeFile(components: components, from: &root) {
            throw Panic("File not found")
        }
    }

    func isDirectory(_ url: URL) throws -> Bool {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let file = findFile(components: components, in: root) else {
            throw Panic("File not found")
        }
        return file.isDirectory
    }

    func isEmptyDirectory(_ url: URL) -> Bool {
        let components = url.pathComponents.filter { $0 != "/" }
        guard let file = findFile(components: components, in: root) else {
            return false
        }
        if case .directory(_, let sub) = file {
            return sub.isEmpty
        }
        return false
    }

    func isRootDir(_ url: URL) -> Bool {
        // Match real FileManager implementation which uses standardizedFileURL
        return url.standardizedFileURL.path == "/"
    }

    func isCrossMountPoint(_ url: URL) throws -> Bool {
        // For mock purposes, we'll always return false
        return false
    }

    func isExist(atPath path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        return findFile(components: components, in: root) != nil
    }

    func subpaths(atPath path: String, enumerator handler: (String) -> Bool) {
        let components = path.split(separator: "/").map(String.init)
        guard let file = findFile(components: components, in: root) else {
            return
        }

        func enumerate(file: FileMock, currentPath: String) {
            switch file {
            case .directory(_, let sub):
                for subFile in sub {
                    let newPath = currentPath.isEmpty ? subFile.name : "\(currentPath)/\(subFile.name)"
                    if handler(newPath) {
                        if case .directory = subFile {
                            enumerate(file: subFile, currentPath: newPath)
                        }
                    }
                }
            default:
                break
            }
        }

        if case .directory = file {
            enumerate(file: file, currentPath: "")
        }
    }

    func currentFileStructure() -> [FileMock] {
        return root
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
        let mockFiles: [FileMock] = [
            .file(name: "test.txt"),
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt")
            ])
        ]
        let fileManager = FileManagerMock(root: mockFiles)

        let trash = makeTrash(force: true, fileManager: fileManager)
        XCTAssertTrue(trash.removeMultiple(paths: ["/test.txt"]))
        assertFileStructure(fileManager, expectedFiles: [
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt")
            ])
        ])
    }

    func testRecursiveConfig() {
        let mockFiles: [FileMock] = [
            .directory(name: "dir1", sub: [
                .file(name: "file1.txt"),
                .directory(name: "subdir", sub: [
                    .file(name: "file2.txt")
                ])
            ])
        ]
        let fileManager = FileManagerMock(root: mockFiles)

        // Test non-recursive config
        let nonRecursiveTrash = makeTrash(fileManager: fileManager)
        XCTAssertFalse(nonRecursiveTrash.removeMultiple(paths: ["/dir1"]))
        assertFileStructure(fileManager, expectedFiles: mockFiles)

        // Test recursive config
        let recursiveTrash = makeTrash(recursive: true, fileManager: fileManager)
        XCTAssertTrue(recursiveTrash.removeMultiple(paths: ["/dir1"]))
        assertFileStructure(fileManager, expectedFiles: [])
    }

    func testEmptyDirsConfig() {
        let mockFiles: [FileMock] = [
            .directory(name: "emptyDir", sub: []),
            .directory(name: "nonEmptyDir", sub: [
                .file(name: "file.txt")
            ])
        ]
        let fileManager = FileManagerMock(root: mockFiles)

        let trash = makeTrash(emptyDirs: true, fileManager: fileManager)
        XCTAssertTrue(trash.removeMultiple(paths: ["/emptyDir"]))
        assertFileStructure(fileManager, expectedFiles: [
            .directory(name: "nonEmptyDir", sub: [
                .file(name: "file.txt")
            ])
        ])
        XCTAssertFalse(trash.removeMultiple(paths: ["/nonEmptyDir"]))
    }

    func testPreserveRootConfig() {
        let mockFiles: [FileMock] = [
            .directory(name: "testdir", sub: [])
        ]
        let fileManager = FileManagerMock(root: mockFiles)

        // Test preserveRoot enabled
        let preserveRootTrash = makeTrash(
            recursive: true,
            emptyDirs: true,
            fileManager: fileManager
        )
        XCTAssertFalse(preserveRootTrash.removeMultiple(paths: ["/"]))
        XCTAssertTrue(preserveRootTrash.removeMultiple(paths: ["/testdir"]))

        // Test preserveRoot disabled
        let nonPreserveRootTrash = makeTrash(
            recursive: true,
            emptyDirs: true,
            preserveRoot: false,
            fileManager: fileManager
        )
        XCTAssertTrue(nonPreserveRootTrash.removeMultiple(paths: ["/"]))
    }

    func testInteractiveModeOnce() {
        let mockFiles: [FileMock] = [
            .file(name: "test1.txt"),
            .directory(name: "dir1", sub: [])
        ]

        // Test with yes answer
        let yesFileManager = FileManagerMock(root: mockFiles)
        let yesTrash = makeTrash(
            interactiveMode: .once,
            force: false,
            recursive: true,
            fileManager: yesFileManager,
            question: StaticAnswer(value: true)
        )
        XCTAssertTrue(yesTrash.removeMultiple(paths: ["/test1.txt", "/dir1"]))
        assertFileStructure(yesFileManager, expectedFiles: [])

        // Test with no answer
        let noFileManager = FileManagerMock(root: mockFiles)
        let noTrash = makeTrash(
            interactiveMode: .once,
            force: false,
            recursive: true,
            fileManager: noFileManager,
            question: StaticAnswer(value: false)
        )
        XCTAssertTrue(noTrash.removeMultiple(paths: ["/test1.txt", "/dir1"]))
        assertFileStructure(noFileManager, expectedFiles: mockFiles)
    }

    func testInteractiveModeAlways() {
        let mockFiles: [FileMock] = [
            .file(name: "test1.txt"),
            .file(name: "test2.txt")
        ]

        // Test with yes answer
        let yesFileManager = FileManagerMock(root: mockFiles)
        let yesTrash = makeTrash(
            interactiveMode: .always,
            force: false,
            fileManager: yesFileManager,
            question: StaticAnswer(value: true)
        )
        XCTAssertTrue(yesTrash.removeMultiple(paths: ["/test1.txt", "/test2.txt"]))
        assertFileStructure(yesFileManager, expectedFiles: [])

        // Test with no answer
        let noFileManager = FileManagerMock(root: mockFiles)
        let noTrash = makeTrash(
            interactiveMode: .always,
            force: false,
            fileManager: noFileManager,
            question: StaticAnswer(value: false)
        )
        XCTAssertTrue(noTrash.removeMultiple(paths: ["/test1.txt", "/test2.txt"]))
        assertFileStructure(noFileManager, expectedFiles: mockFiles)
    }

    func testFileListStateAfterDeletion() {
        let initialFiles: [FileMock] = [
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
        let fileManager = FileManagerMock(root: initialFiles)
        let trash = makeTrash(recursive: true, emptyDirs: true, fileManager: fileManager)

        // Test single file deletion
        XCTAssertTrue(trash.removeMultiple(paths: ["/test1.txt"]))
        assertFileStructure(fileManager, expectedFiles: [
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
        XCTAssertTrue(trash.removeMultiple(paths: ["/dir1"]))
        assertFileStructure(fileManager, expectedFiles: [
            .file(name: "test2.txt")
        ])

        // Test remaining file deletion
        XCTAssertTrue(trash.removeMultiple(paths: ["/test2.txt"]))
        assertFileStructure(fileManager, expectedFiles: [])
    }
    
    
    func testRemoveSymlink() {
        let trash = Trash(config: Trash.Config.init(interactiveMode: .never, force: true, recursive: true, emptyDirs: true, preserveRoot: true, oneFileSystem: true, verbose: true))
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appending(path: "no_such_file")
        let link = dir.appending(path: "sym.link")
        XCTAssertNoThrow(try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file))
        XCTAssertTrue(trash.removeMultiple(paths: [link.path]))
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
            fileManager: fileManager ?? FileManagerMock(root: [])
        )
    }

    func assertFileStructure(_ fileManager: FileManagerMock, expectedFiles: [FileMock], file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(fileManager.currentFileStructure(), expectedFiles, file: file, line: line)
    }
}
