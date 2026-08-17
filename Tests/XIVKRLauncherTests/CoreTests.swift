import Foundation
import XCTest
@testable import XIVKRLauncher
#if canImport(Darwin)
import Darwin
#endif

private func testResponse(_ data: Data, status: Int = 200, headers: [String: String] = [:]) -> DownloadResponse {
    let body = AsyncThrowingStream<Data, Error> { continuation in
        continuation.yield(data)
        continuation.finish()
    }
    return DownloadResponse(statusCode: status, headers: headers, body: body)
}

final class CoreTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xiv-kr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func manifestJSON(url: String = "http://fcdp.ff14.co.kr/game/", files: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["URL": url, "FileList": files])
    }

    func testSafeRelativePathRejectsWindowsAndTraversalForms() throws {
        XCTAssertEqual(try safeRelativePath("/game/file.bin"), "game/file.bin")
        for value in ["../outside", "%2e%2e/outside", "folder%5c..%5coutside", "folder\\file", "C:/outside", "C:%5Coutside", "//server/share", "folder//file", "folder/./file", "bad\0name"] {
            XCTAssertThrowsError(try safeRelativePath(value), "unsafe path should be rejected: \(value)")
        }
    }

    func testManifestParsingCanonicalizesAndValidates() throws {
        let data = try manifestJSON(files: [
            ["Name": "/game.bin", "Size": 4, "CheckSum": "AABBCCDDEEFF00112233445566778899"]
        ])
        let manifest = try Manifest.parse(data: data)
        XCTAssertEqual(manifest.url.absoluteString, "https://fcdp.ff14.co.kr/game/")
        XCTAssertEqual(manifest.files[0].name, "game.bin")
        XCTAssertEqual(manifest.files[0].md5, "aabbccddeeff00112233445566778899")

        let unsafeURL = try manifestJSON(url: "https://example.com/game/", files: [["Name": "x", "Size": 1, "CheckSum": String(repeating: "a", count: 32)]])
        XCTAssertThrowsError(try Manifest.parse(data: unsafeURL))
        let duplicate = try manifestJSON(files: [
            ["Name": "x", "Size": 1, "CheckSum": String(repeating: "a", count: 32)],
            ["Name": "/x", "Size": 1, "CheckSum": String(repeating: "a", count: 32)]
        ])
        XCTAssertThrowsError(try Manifest.parse(data: duplicate))
        let fileURL = try fileURL(base: manifest.url, name: "folder/a.bin")
        XCTAssertEqual(fileURL.absoluteString, "https://fcdp.ff14.co.kr/game/folder/a.bin")
    }

    func testMD5AndManifestDiff() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("payload")
        try Data("the korean game file".utf8).write(to: file)
        XCTAssertEqual(try md5File(at: file), "bbd1f7e1cdcdb080d9eabd16f24b6a98")
        let same = try ManifestFile(name: "same", size: 1, md5: String(repeating: "a", count: 32))
        let changed = try ManifestFile(name: "changed", size: 2, md5: String(repeating: "b", count: 32))
        XCTAssertEqual(manifestDiff(previous: [same], current: [same, changed]).map(\.name), ["changed"])
    }

    func testGameVersionReadsAndRejectsUnexpectedContent() throws {
        XCTAssertEqual(validatedGameVersion("2026.05.25.0000.0000"), "2026.05.25.0000.0000")
        XCTAssertEqual(validatedGameVersion("2026.05.25.0000.0000\n"), "2026.05.25.0000.0000")
        for invalid in ["", ".2026.05", "2026..05", "2026.05.", "2026.05.25 beta", "2026/05/25", String(repeating: "1", count: 65)] {
            XCTAssertEqual(validatedGameVersion(invalid), "-", "invalid version should be hidden: \(invalid)")
        }

        let root = try temporaryDirectory()
        let version = root.appendingPathComponent("ffxivgame.ver")
        try Data("2026.05.25.0000.0000".utf8).write(to: version)
        XCTAssertEqual(readGameVersion(at: root), "2026.05.25.0000.0000")

        try Data("not-a-version".utf8).write(to: version)
        XCTAssertEqual(readGameVersion(at: root), "-")
        XCTAssertEqual(GameVersions(current: "not-a-version", latest: "2026.05.25").current, "-")
    }

    func testOfficialGameStatusUsesFfxivGameVersionNotManifestMetadata() throws {
        let equal = GameVersionStatus(
            current: "2026.05.25.0000.0000",
            latest: "2026.05.25.0000.0000",
            installed: true
        )
        XCTAssertEqual(equal.launcherStatus, "2")
        XCTAssertEqual(equal.appGameStatusArgument, "2;2026.05.25.0000.0000;2026.05.25.0000.0000")

        let older = GameVersionStatus(
            current: "2026.05.15.0000.0000",
            latest: "2026.05.25.0000.0000",
            installed: true
        )
        XCTAssertEqual(older.launcherStatus, "1")
        XCTAssertEqual(older.appGameStatusArgument, "1;2026.05.15.0000.0000;2026.05.25.0000.0000")

        let expansionUpdate = GameVersionStatus(
            current: "2026.05.25.0000.0000",
            latest: "2026.05.25.0000.0000",
            installed: true,
            updateRequired: true
        )
        XCTAssertEqual(expansionUpdate.launcherStatus, "1")
        XCTAssertEqual(expansionUpdate.appGameStatusArgument, "1;2026.05.25.0000.0000;2026.05.25.0000.0000")

        let fresh = GameVersionStatus(current: "-", latest: "-", installed: false)
        XCTAssertEqual(fresh.launcherStatus, "0")
        XCTAssertEqual(fresh.appGameStatusArgument, "0;-;-" )

        // FileListGame.json's top-level Version is deliberately not used as
        // the client version. It is a maintenance/file-list identifier.
        let data = try JSONSerialization.data(withJSONObject: [
            "Version": "2026.06.02.01",
            "URL": "http://fcdp.ff14.co.kr/game/",
            "FileList": [[
                "Name": "ffxivgame.ver",
                "Size": 20,
                "CheckSum": "c8db4066ee3481da0d9694270b64d46c"
            ]]
        ])
        let manifest = try Manifest.parse(data: data)
        XCTAssertEqual(manifest.files.first?.name, "ffxivgame.ver")
    }

    func testFetchLatestGameVersionReadsAndVerifiesVersionFile() async throws {
        let versionData = Data("2026.05.25.0000.0000".utf8)
        let versionMD5 = try md5(versionData)
        let file = try ManifestFile(name: "ffxivgame.ver", size: Int64(versionData.count), md5: versionMD5)
        let manifest = try Manifest(url: URL(string: "https://fcdp.ff14.co.kr/game/")!, files: [file])
        let fetcher: DownloadFetcher = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            XCTAssertEqual(request.url?.absoluteString, "https://fcdp.ff14.co.kr/game/ffxivgame.ver")
            return testResponse(versionData, status: 200)
        }
        let latest = try await fetchLatestGameVersion(from: manifest, fetcher: fetcher)
        XCTAssertEqual(latest, "2026.05.25.0000.0000")

        let wrongFetcher: DownloadFetcher = { _ in
            testResponse(Data("2026.05.15.0000.0000".utf8), status: 200)
        }
        do {
            _ = try await fetchLatestGameVersion(from: manifest, fetcher: wrongFetcher)
            XCTFail("a version file with a different size or MD5 must be rejected")
        } catch {
            // expected
        }
    }

    func testOfficialActozPatchListParsesAndPinsPayloadHosts() throws {
        let sha1 = "81fe8bfe87576c3ecb22426f8e57847382917acf"
        let body = [
            "--fixture",
            "Content-Type: application/octet-stream",
            "Content-Location: ffxivpatch/de199059/metainfo/2026.05.25.0000.0000.http",
            "X-Patch-Length: 4",
            "",
            "4\t4\t71\t12\t2026.06.09.0000.0000\tsha1\t4\t\(sha1)\thttp://client-patch-live.ff14.co.kr/game/de199059/D2026.06.09.0000.0000.patch",
            "--fixture--",
            ""
        ].joined(separator: "\r\n")
        let patches = try parseOfficialPatchList(Data(body.utf8))
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches[0].repository, .game)
        XCTAssertEqual(patches[0].url.absoluteString, "https://client-patch-live.ff14.co.kr/game/de199059/D2026.06.09.0000.0000.patch")
        XCTAssertEqual(patches[0].sha1Blocks, [sha1])
        XCTAssertThrowsError(try OfficialPatch(
            repository: .game,
            version: "2026.06.09.0000.0000",
            size: 4,
            blockSize: 4,
            sha1Blocks: [sha1],
            url: URL(string: "https://example.com/game/de199059/D2026.06.09.0000.0000.patch")!
        ))
    }

    func testOfficialPatchFetcherUsesActozRequestAndAllowsEmptyLatestBody() async throws {
        let calls = Counter()
        let empty = Data("--fixture\r\nContent-Type: application/octet-stream\r\n\r\n--fixture--\r\n".utf8)
        let patches = try await fetchOfficialPatchList(baseVersion: "2026.08.05.0000.0000") { request in
            calls.value += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "http://ngamever-live.ff14.co.kr/http/win32/actoz_release_ko_game/2026.08.05.0000.0000/")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "FFXIV_Patch")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Hash-Check"), "enabled")
            return OfficialPatchResponse(statusCode: 200, body: empty)
        }
        XCTAssertEqual(calls.value, 1)
        XCTAssertTrue(patches.isEmpty)
    }

    func testOfficialPatchPlanSkipsCurrentAndHandlesOmittedNoopVersion() throws {
        let sha1 = "81fe8bfe87576c3ecb22426f8e57847382917acf"
        func patch(_ repository: PatchRepository, _ version: String) throws -> OfficialPatch {
            let path = repository == .game
                ? "game/de199059"
                : "game/\(repository.rawValue)/\(repository.endpointID)"
            return try OfficialPatch(
                repository: repository,
                version: version,
                size: 4,
                blockSize: 4,
                sha1Blocks: [sha1],
                url: URL(string: "http://client-patch-live.ff14.co.kr/\(path)/\(version).patch")!
            )
        }
        var patches: [OfficialPatch] = []
        for repository in PatchRepository.allCases {
            if repository == .ex3 {
                patches += [try patch(repository, "2026.04.10.0000.0001"), try patch(repository, "2026.08.05.0000.0000")]
            } else {
                patches += [try patch(repository, "2026.05.25.0000.0000"), try patch(repository, "2026.08.05.0000.0000")]
            }
        }
        let current = Dictionary(uniqueKeysWithValues: PatchRepository.allCases.map { ($0, "2026.05.25.0000.0000") })
        let plan = try officialPatchPlan(patches: patches, current: current)
        XCTAssertEqual(plan.patches.filter { $0.repository == .game }.map(\.version), ["2026.08.05.0000.0000"])
        XCTAssertEqual(plan.patches.filter { $0.repository == .ex3 }.map(\.version), ["2026.08.05.0000.0000"])
        XCTAssertEqual(plan.latestGameVersion, "2026.08.05.0000.0000")

        let emptyPlan = try officialPatchPlan(
            patches: patches.filter { $0.repository != .game },
            current: current,
            requestedBaseVersion: "2026.08.05.0000.0000"
        )
        XCTAssertEqual(emptyPlan.latestGameVersion, "2026.08.05.0000.0000")
    }

    func testOfficialPatchDownloadVerifiesAndFakeHelperUpdatesVersion() async throws {
        let root = try temporaryDirectory()
        let payload = Data("abcd".utf8)
        let sha1 = "81fe8bfe87576c3ecb22426f8e57847382917acf"
        let patch = try OfficialPatch(
            repository: .game,
            version: "2026.06.09.0000.0000",
            size: Int64(payload.count),
            blockSize: Int64(payload.count),
            sha1Blocks: [sha1],
            url: URL(string: "http://client-patch-live.ff14.co.kr/game/de199059/D2026.06.09.0000.0000.patch")!
        )
        let plan = OfficialPatchPlan(
            patches: [patch],
            current: [.game: "2026.05.25.0000.0000"],
            latest: [.game: "2026.06.09.0000.0000"]
        )
        let calls = Counter()
        let fetcher: DownloadFetcher = { request in
            calls.value += 1
            XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
            XCTAssertEqual(request.url?.absoluteString, patch.url.absoluteString)
            return testResponse(payload)
        }
        let helperCalls = Counter()
        _ = try await applyOfficialPatchPlan(plan, at: root, fetcher: fetcher, applier: { patchURL, gameRoot in
            helperCalls.value += 1
            XCTAssertTrue(FileManager.default.fileExists(atPath: patchURL.path))
            XCTAssertEqual(gameRoot, root)
        })
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(helperCalls.value, 1)
        XCTAssertEqual(readGameVersion(at: root), "2026.06.09.0000.0000")
        XCTAssertEqual(String(data: try Data(contentsOf: root.appendingPathComponent("ffxivgame.bck")), encoding: .utf8), "2026.06.09.0000.0000")
    }

    func testMD5UsesFixedMemoryForLargeSparseFile() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("large-sparse-payload")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 512 * 1024 * 1024)
        try handle.close()

        // Warm up CryptoKit and the task-info query so lazy framework pages do
        // not count as checksum working memory.
        _ = try md5File(at: file)
        let before = residentSize()
        let digest = try md5File(at: file)
        let after = residentSize()

        XCTAssertFalse(digest.isEmpty)
        XCTAssertEqual(checksumBufferSize, 4 * 1024 * 1024)
        if before > 0, after > before {
            // A sparse 512 MiB file must not make RSS follow the input size.
            // Keep this deliberately generous for allocator/framework noise.
            XCTAssertLessThan(after - before, 64 * 1024 * 1024)
        }
    }

    func testDownloadBodyIsBoundedAndUsesFourMiBOrSmallerChunks() async throws {
        let chunkLimit = downloadChunkSize
        let bufferCapacity = downloadChunkBufferCapacity
        let produced = Counter()
        let stream = boundedDataStream { emit in
            for index in 0..<32 {
                produced.value += 1
                try await emit(Data(repeating: UInt8(index), count: chunkLimit))
            }
        }

        // The producer may have enqueued the bounded queue and started one
        // next emit, but it must not run to completion while the consumer is
        // paused. An unbounded AsyncThrowingStream would reach 32 here.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertLessThanOrEqual(produced.value, bufferCapacity + 1)

        var count = 0
        var largest = 0
        for try await chunk in stream {
            count += 1
            largest = max(largest, chunk.count)
        }
        XCTAssertEqual(count, 32)
        XCTAssertLessThanOrEqual(largest, chunkLimit)
    }

    func testSequentialDownloadResumesAndSkipsVerifiedFile() async throws {
        let root = try temporaryDirectory()
        let data = Data("the korean game file".utf8)
        try data.prefix(5).write(to: root.appendingPathComponent("game.bin.part"))
        let file = try ManifestFile(name: "game.bin", size: Int64(data.count), md5: try md5(data))
        let manifest = try Manifest(url: URL(string: "https://fcdp.ff14.co.kr/game/")!, files: [file])
        let counter = Counter()
        let fetcher: DownloadFetcher = { request in
            counter.value += 1
            if let range = request.value(forHTTPHeaderField: "Range"),
               let offsetText = range.split(separator: "=").last?.split(separator: "-").first,
               let offset = Int64(offsetText) {
                return testResponse(Data(data.dropFirst(Int(offset))), status: 206, headers: [
                    "Content-Range": "bytes \(offset)-\(data.count - 1)/\(data.count)",
                    "Content-Length": "\(data.count - Int(offset))"
                ])
            }
            return testResponse(data)
        }
        try await installManifest(manifest, at: root, fetcher: fetcher)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("game.bin")), data)
        XCTAssertEqual(counter.value, 1)

        // An identical successful manifest is trusted on startup.  It must
        // not perform another full-file checksum read merely to decide that
        // no update is needed.
        try Data(repeating: 0x78, count: data.count).write(to: root.appendingPathComponent("game.bin"))
        try await installManifest(manifest, at: root, fetcher: fetcher)
        XCTAssertEqual(counter.value, 1, "a verified unchanged file should not download again")

        // A changed manifest still downloads and verifies only the changed
        // entry; unchanged entries remain trusted from the previous state.
        let changedData = Data("the changed game file".utf8)
        let changedFile = try ManifestFile(name: "game.bin", size: Int64(changedData.count), md5: try md5(changedData))
        let changedManifest = try Manifest(url: manifest.url, files: [changedFile])
        let changedCounter = Counter()
        let changedFetcher: DownloadFetcher = { _ in
            changedCounter.value += 1
            return testResponse(changedData)
        }
        try await installManifest(changedManifest, at: root, fetcher: changedFetcher)
        XCTAssertEqual(changedCounter.value, 1, "a changed manifest should download only its changed entry")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("game.bin")), changedData)
    }

    func testRangeNetworkFailureFallsBackToFullAndServer200TruncatesPart() async throws {
        let root = try temporaryDirectory()
        let data = Data("complete payload".utf8)
        try Data(data.prefix(4)).write(to: root.appendingPathComponent("game.bin.part"))
        let file = try ManifestFile(name: "game.bin", size: Int64(data.count), md5: try md5(data))
        let manifest = try Manifest(url: manifestURL, files: [file])
        let counter = Counter()
        let fetcher: DownloadFetcher = { request in
            counter.value += 1
            if request.value(forHTTPHeaderField: "Range") != nil {
                throw URLError(.cannotLoadFromNetwork)
            }
            return testResponse(data, status: 200)
        }
        try await installManifest(manifest, at: root, fetcher: fetcher)
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("game.bin")), data)
    }

    func testInvalidRangeFallsBackToFullResponse() async throws {
        let root = try temporaryDirectory()
        let data = Data("range payload".utf8)
        try Data(data.prefix(3)).write(to: root.appendingPathComponent("game.bin.part"))
        let file = try ManifestFile(name: "game.bin", size: Int64(data.count), md5: try md5(data))
        let manifest = try Manifest(url: manifestURL, files: [file])
        let counter = Counter()
        let fetcher: DownloadFetcher = { request in
            counter.value += 1
            if request.value(forHTTPHeaderField: "Range") != nil {
                return testResponse(Data("wrong".utf8), status: 206, headers: ["Content-Range": "bytes 0-4/13"])
            }
            return testResponse(data)
        }
        try await installManifest(manifest, at: root, fetcher: fetcher)
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("game.bin")), data)
    }

    func testTokenAndStandaloneWineArguments() throws {
        let token = String(repeating: "A", count: 44)
        let launch = try buildLaunchArguments(token: token)
        XCTAssertTrue(launch.contains("DEV.LobbyHost01=nlobbyf-live.ff14.co.kr"))
        XCTAssertTrue(launch.contains("DEV.GMServerHost=ngm-live.ff14.co.kr"))
        XCTAssertTrue(launch.contains("DEV.SaveDataBankHost=nconfig-dl-live.ff14.co.kr"))
        XCTAssertThrowsError(try validateToken("secret"))
        XCTAssertEqual(try buildWineArguments(token: token).first, "ffxiv_dx11.exe")

        let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = WineRuntime(baseURL: resources)
        XCTAssertEqual(runtime.wine, resources.appendingPathComponent("wine/bin/wine"))
        let prefix = resources.appendingPathComponent("prefix")
        let environment = runtime.environment(prefixURL: prefix, base: ["PATH": "/usr/bin"])
        XCTAssertEqual(environment["WINEPREFIX"], prefix.path)
        XCTAssertEqual(environment["WINEARCH"], "win64")
        XCTAssertEqual(environment["WINEMSYNC"], "1")
        XCTAssertEqual(environment["DXMT_ENABLE_NVEXT"], "1")
        XCTAssertEqual(environment["WINEDLLOVERRIDES"], "d3dcompiler_47=n,b")
        XCTAssertTrue(environment["PATH"]?.hasPrefix(resources.appendingPathComponent("wine/bin").path) == true)
    }

    func testRuntimeArchiveRequiresPinnedHashAndInstallsAtomically() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent(
            "fixture/XIV on Mac.app/Contents/Resources",
            isDirectory: true
        )
        let fixture = resources.appendingPathComponent("wine", isDirectory: true)
        let wine = fixture.appendingPathComponent("bin/wine")
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixture.appendingPathComponent("lib/wine", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let compiler = resources.appendingPathComponent("d3dcompiler/d3dcompiler_47.dll")
        try FileManager.default.createDirectory(at: compiler.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("dll".utf8).write(to: compiler)

        let archive = root.appendingPathComponent("runtime.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = [
            "-czf", archive.path,
            "-C", root.appendingPathComponent("fixture").path,
            "XIV on Mac.app/Contents/Resources/wine",
            "XIV on Mac.app/Contents/Resources/d3dcompiler"
        ]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let destination = WineRuntime(baseURL: root.appendingPathComponent("installed/current"))
        await XCTAssertThrowsErrorAsync {
            try await installRuntimeArchive(
                archive,
                expectedSHA256: String(repeating: "0", count: 64),
                runtime: destination
            )
        }
        try await installRuntimeArchive(
            archive,
            expectedSHA256: try sha256File(at: archive),
            runtime: destination
        )
        XCTAssertTrue(destination.isInstalled)
    }

    private func md5(_ data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try md5File(at: url)
    }

    private func residentSize() -> UInt64 {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        #else
        return 0
        #endif
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {}
}
