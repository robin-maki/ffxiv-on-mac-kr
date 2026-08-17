import Foundation
import XCTest
@testable import XIVKRLauncher

final class ConfigTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xivkr-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testPatchesTabLineAndKeepsOneBackup() throws {
        let root = try temporaryDirectory()
        let config = root.appendingPathComponent("FFXIV.cfg")
        let original = "<Cutscene Settings>\r\nCutsceneMovieOpening\t0\r\nOther\t2\r\n"
        try Data(original.utf8).write(to: config)

        XCTAssertTrue(try enableOpeningMovieSkip(at: config))
        XCTAssertEqual(try String(contentsOf: config), original.replacingOccurrences(of: "\t0", with: "\t1"))
        let backup = config.appendingPathExtension("xivkr-backup")
        XCTAssertEqual(try String(contentsOf: backup), original)

        XCTAssertFalse(try enableOpeningMovieSkip(at: config))
        XCTAssertEqual(try String(contentsOf: backup), original)
    }

    func testPatchesEqualsWithoutDoubleEquals() throws {
        let root = try temporaryDirectory()
        let config = root.appendingPathComponent("FFXIV.cfg")
        try Data("CutsceneMovieOpening = 0\n".utf8).write(to: config)
        XCTAssertTrue(try enableOpeningMovieSkip(at: config))
        XCTAssertEqual(try String(contentsOf: config), "CutsceneMovieOpening = 1\n")
    }

    func testRejectsMissingOrDuplicateKey() throws {
        let root = try temporaryDirectory()
        let config = root.appendingPathComponent("FFXIV.cfg")
        try Data("Other\t0\n".utf8).write(to: config)
        XCTAssertThrowsError(try enableOpeningMovieSkip(at: config))
        try Data("CutsceneMovieOpening\t0\nCutsceneMovieOpening\t0\n".utf8).write(to: config)
        XCTAssertThrowsError(try enableOpeningMovieSkip(at: config))
    }

    func testResolverUsesExistingAllowedDocumentsSymlink() throws {
        let root = try temporaryDirectory()
        let home = root.appendingPathComponent("home", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let bottle = root.appendingPathComponent("bottle", isDirectory: true)
        let user = bottle.appendingPathComponent("drive_c/users/crossover", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: user.appendingPathComponent("Documents"),
            withDestinationURL: documents
        )
        let config = documents.appendingPathComponent(ffxivConfigRelativePathForTests)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("CutsceneMovieOpening\t0\n".utf8).write(to: config)
        XCTAssertEqual(try findExistingFFXIVConfig(bottleURL: bottle, homeURL: home)?.path, config.path)
    }
}

private let ffxivConfigRelativePathForTests = "My Games/FINAL FANTASY XIV - KOREA/FFXIV.cfg"
