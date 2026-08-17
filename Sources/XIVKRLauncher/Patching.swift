import CryptoKit
import Darwin
import Foundation

private func patchFinalURL(root: URL, name: String) throws -> URL {
    let relative = try safeRelativePath(name)
    let target = root.appendingPathComponent(relative)
    let rootPath = root.standardizedFileURL.path
    let targetPath = target.standardizedFileURL.path
    guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
        throw LauncherError.path("파일 경로가 게임 디렉터리를 벗어납니다.")
    }
    return target
}

private func patchMakeRequest(url: URL, range: Int64?) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    if let range { request.setValue("bytes=\(range)-", forHTTPHeaderField: "Range") }
    return request
}

private func patchHeader(_ response: DownloadResponse, _ name: String) -> String? {
    response.headers[name.lowercased()]
}

private func patchRangeStart(_ response: DownloadResponse) -> (start: Int64, end: Int64, total: Int64?)? {
    guard let value = patchHeader(response, "content-range") else { return nil }
    let pattern = #"^bytes\s+(\d+)-(\d+)/(\d+|\*)$"#
    guard let match = value.range(of: pattern, options: .regularExpression) else { return nil }
    let fields = value[match].split { $0 == " " || $0 == "-" || $0 == "/" }.map(String.init)
    guard fields.count == 4,
          let start = Int64(fields[1]), let end = Int64(fields[2]) else { return nil }
    let total = fields[3] == "*" ? nil : Int64(fields[3])
    return (start, end, total)
}

/// The five game repositories are patched independently, but the official
/// Actoz version response lists them in one response. Keep the mapping
/// explicit: accepting a caller-supplied repository path would turn a version
/// check into an arbitrary-host/file operation.
public enum PatchRepository: String, CaseIterable, Codable, Sendable {
    case game
    case ex1
    case ex2
    case ex3
    case ex4
    case ex5

    var endpointID: String {
        switch self {
        case .game: return "de199059"
        case .ex1: return "573d8c07"
        case .ex2: return "ce34ddbd"
        case .ex3: return "b933ed2b"
        case .ex4: return "27577888"
        case .ex5: return "5050481e"
        }
    }

    var versionFileURLPath: String {
        switch self {
        case .game: return "ffxivgame.ver"
        case .ex1, .ex2, .ex3, .ex4, .ex5:
            return "sqpack/\(rawValue)/\(rawValue).ver"
        }
    }

    func versionURL(at gameRoot: URL) throws -> URL {
        try patchFinalURL(root: gameRoot, name: versionFileURLPath)
    }

    static func fromPatchPath(_ path: [String]) -> PatchRepository? {
        guard path.first == "game" else { return nil }
        if path.count == 3, path[1] == "de199059" {
            return .game
        }
        guard path.count == 4, let repository = allCases.first(where: { $0.rawValue == path[1] }) else {
            return nil
        }
        return repository.endpointID == path[2] ? repository : nil
    }
}

public struct OfficialPatch: Equatable, Sendable {
    public let repository: PatchRepository
    public let version: String
    public let size: Int64
    public let blockSize: Int64
    public let sha1Blocks: [String]
    public let url: URL

    public init(
        repository: PatchRepository,
        version: String,
        size: Int64,
        blockSize: Int64,
        sha1Blocks: [String],
        url: URL
    ) throws {
        guard validatedPatchVersion(version) != nil else {
            throw LauncherError.manifest("공식 패치 버전 형식이 올바르지 않습니다.")
        }
        guard size > 0, blockSize > 0 else {
            throw LauncherError.manifest("공식 패치 크기가 올바르지 않습니다.")
        }
        let expectedBlocks = (size + blockSize - 1) / blockSize
        guard expectedBlocks == Int64(sha1Blocks.count), !sha1Blocks.isEmpty,
              sha1Blocks.allSatisfy({ $0.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil }) else {
            throw LauncherError.manifest("공식 패치 SHA1 목록이 올바르지 않습니다.")
        }
        self.repository = repository
        self.version = version
        self.size = size
        self.blockSize = blockSize
        self.sha1Blocks = sha1Blocks.map { $0.lowercased() }
        self.url = try officialPatchURL(url, repository: repository, version: version)
    }
}

public struct OfficialPatchResponse: Sendable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public typealias PatchMetadataFetcher = @Sendable (URLRequest) async throws -> OfficialPatchResponse

public let officialPatchMetadataFetcher: PatchMetadataFetcher = { request in
    let (data, response) = try await URLSession.shared.data(for: request)
    return OfficialPatchResponse(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
}

public let officialPatchEndpointHost = "ngamever-live.ff14.co.kr"
public let officialPatchPayloadHost = "client-patch-live.ff14.co.kr"

public func officialPatchEndpointURL(baseVersion: String) throws -> URL {
    guard validatedGameVersion(baseVersion) != "-" else {
        throw LauncherError.manifest("게임 버전이 올바르지 않아 패치 목록을 확인할 수 없습니다.")
    }
    let url = URL(string: "http://\(officialPatchEndpointHost)/http/win32/actoz_release_ko_game/\(baseVersion)/")!
    guard url.scheme == "http", url.host == officialPatchEndpointHost,
          url.query == nil, url.fragment == nil else {
        throw LauncherError.manifest("공식 패치 목록 URL이 올바르지 않습니다.")
    }
    return url
}

public func officialPatchURL(_ rawURL: URL, repository: PatchRepository, version: String) throws -> URL {
    guard let scheme = rawURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
          rawURL.host?.lowercased() == officialPatchPayloadHost,
          rawURL.user == nil, rawURL.password == nil,
          rawURL.port == nil || rawURL.port == (scheme == "http" ? 80 : 443),
          rawURL.query == nil, rawURL.fragment == nil else {
        throw LauncherError.manifest("공식 패치 CDN URL이 아닙니다.")
    }
    let encodedPath = URLComponents(url: rawURL, resolvingAgainstBaseURL: false)?.percentEncodedPath.lowercased() ?? ""
    guard !encodedPath.contains("%2e"), !encodedPath.contains("%2f"), !encodedPath.contains("%5c") else {
        throw LauncherError.path("공식 패치 URL의 경로 인코딩이 허용되지 않습니다.")
    }
    let path = rawURL.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard PatchRepository.fromPatchPath(path) == repository,
          path.last.map({ officialPatchFilenameMatches($0, version: version) }) == true else {
        throw LauncherError.manifest("공식 패치 URL과 버전이 일치하지 않습니다.")
    }
    var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false)!
    components.scheme = "https"
    components.port = nil
    return components.url!
}

/// Validate the filename relationship in an Actoz patch row. Most rows use
/// `D<version>.patch`, but historical expansion chains end with a row whose
/// metadata version is numeric while the payload is named
/// `H<version><chunk>.patch` (for example `H2024....0000d.patch`). Rows whose
/// metadata already carries an `H`/`D` prefix are exact and must not acquire a
/// second prefix or an arbitrary suffix.
private func officialPatchFilenameMatches(_ filename: String, version: String) -> Bool {
    guard filename.count <= 160,
          filename.range(of: "^[A-Za-z0-9._-]+\\.patch$", options: .regularExpression) != nil,
          let validated = validatedPatchVersion(version) else { return false }
    let stem = String(filename.dropLast(".patch".count))

    if validated.first == "H" || validated.first == "D" {
        return stem == validated
    }

    let escaped = NSRegularExpression.escapedPattern(for: validated)
    return stem == validated || stem == "D" + validated ||
        stem.range(of: "^H\(escaped)[a-z]+$", options: .regularExpression) != nil
}

/// Versions in the official response can be history chunks (`H...a`) as well
/// as normal dotted client versions. The game `.ver` file is numeric after a
/// completed chain; keeping this parser separate avoids treating an H chunk
/// as a UI version.
public func validatedPatchVersion(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count <= 96,
          value.range(of: "^(?:H|D)?[0-9]{4}(?:\\.[0-9]{2}){1,2}\\.[0-9]{4}\\.[0-9]{4}[a-z]*$", options: .regularExpression) != nil else {
        return nil
    }
    return value
}

private struct PatchVersionKey: Comparable {
    let numbers: [Int]
    let suffix: String

    init?(_ raw: String) {
        guard let value = validatedPatchVersion(raw) else { return nil }
        let withoutPrefix = value.first == "H" || value.first == "D" ? String(value.dropFirst()) : value
        guard let match = withoutPrefix.range(of: "[0-9.]+", options: .regularExpression),
              match.lowerBound == withoutPrefix.startIndex else { return nil }
        let parts = withoutPrefix[..<match.upperBound].split(separator: ".")
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        self.numbers = numbers
        self.suffix = String(withoutPrefix[match.upperBound...])
    }

    static func < (lhs: PatchVersionKey, rhs: PatchVersionKey) -> Bool {
        for (left, right) in zip(lhs.numbers, rhs.numbers) where left != right { return left < right }
        if lhs.numbers.count != rhs.numbers.count { return lhs.numbers.count < rhs.numbers.count }
        return lhs.suffix.localizedStandardCompare(rhs.suffix) == .orderedAscending
    }
}

private func patchVersionCompare(_ lhs: String, _ rhs: String) -> ComparisonResult {
    guard let left = PatchVersionKey(lhs), let right = PatchVersionKey(rhs) else { return .orderedSame }
    if left < right { return .orderedAscending }
    if right < left { return .orderedDescending }
    return .orderedSame
}

public func parseOfficialPatchList(_ data: Data) throws -> [OfficialPatch] {
    let text = String(decoding: data, as: UTF8.self)
    let lines = text.components(separatedBy: "\r\n")
    guard let boundary = lines.first, boundary.hasPrefix("--"), boundary.count > 2 else {
        throw LauncherError.manifest("공식 패치 목록 경계가 올바르지 않습니다.")
    }
    guard let headerEnd = lines.dropFirst().firstIndex(of: "") else {
        throw LauncherError.manifest("공식 패치 목록 헤더가 올바르지 않습니다.")
    }
    let closingBoundary = boundary + "--"
    guard let closingIndex = lines.firstIndex(of: closingBoundary), closingIndex > headerEnd else {
        throw LauncherError.manifest("공식 패치 목록 본문이 올바르지 않습니다.")
    }
    guard lines.dropFirst(closingIndex + 1).allSatisfy(\.isEmpty) else {
        throw LauncherError.manifest("공식 패치 목록 뒤에 예기치 않은 데이터가 있습니다.")
    }
    for header in lines[1..<headerEnd] {
        if header.lowercased().hasPrefix("x-patch-length:") {
            let rawLength = header.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            guard let length = Int64(rawLength.trimmingCharacters(in: .whitespaces)), length >= 0 else {
                throw LauncherError.manifest("공식 패치 목록 크기 헤더가 올바르지 않습니다.")
            }
        }
    }

    var patches: [OfficialPatch] = []
    for line in lines[(headerEnd + 1)..<closingIndex] where !line.isEmpty {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 9,
              let size = Int64(fields[0]), size > 0,
              fields[1...3].allSatisfy({ Int64($0).map { $0 >= 0 } ?? false }),
              let version = validatedPatchVersion(fields[4]),
              fields[5].lowercased() == "sha1",
              let blockSize = Int64(fields[6]), blockSize > 0 else {
            throw LauncherError.manifest("공식 패치 목록 항목이 올바르지 않습니다.")
        }
        let hashes = fields[7].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard let rawURL = URL(string: fields[8]) else {
            throw LauncherError.manifest("공식 패치 URL이 올바르지 않습니다.")
        }
        let path = rawURL.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let repository = PatchRepository.fromPatchPath(path) else {
            throw LauncherError.manifest("지원하지 않는 공식 패치 저장소입니다.")
        }
        patches.append(try OfficialPatch(
            repository: repository,
            version: version,
            size: size,
            blockSize: blockSize,
            sha1Blocks: hashes,
            url: rawURL
        ))
    }
    return patches
}

public func fetchOfficialPatchList(
    baseVersion: String,
    fetcher: @escaping PatchMetadataFetcher = officialPatchMetadataFetcher
) async throws -> [OfficialPatch] {
    let url = try officialPatchEndpointURL(baseVersion: baseVersion)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = Data()
    request.setValue("FFXIV_Patch", forHTTPHeaderField: "User-Agent")
    request.setValue("enabled", forHTTPHeaderField: "X-Hash-Check")
    let response: OfficialPatchResponse
    do {
        response = try await fetcher(request)
    } catch is CancellationError {
        throw LauncherError.cancelled
    } catch {
        throw LauncherError.network("공식 패치 목록을 가져오지 못했습니다.")
    }
    guard response.statusCode == 200 else {
        throw LauncherError.network("공식 패치 목록을 가져오지 못했습니다. (HTTP \(response.statusCode))")
    }
    return try parseOfficialPatchList(response.body)
}

public struct OfficialPatchPlan: Sendable {
    public let patches: [OfficialPatch]
    public let current: [PatchRepository: String]
    public let latest: [PatchRepository: String]

    public var hasUpdates: Bool { !patches.isEmpty }
    public var latestGameVersion: String { latest[.game] ?? "-" }

    public init(patches: [OfficialPatch], current: [PatchRepository: String], latest: [PatchRepository: String]) {
        self.patches = patches
        self.current = current
        self.latest = latest
    }
}

public func readPatchRepositoryVersions(at gameRoot: URL) -> [PatchRepository: String] {
    Dictionary(uniqueKeysWithValues: PatchRepository.allCases.map { repository in
        let url = try? repository.versionURL(at: gameRoot)
        let data = url.flatMap { try? Data(contentsOf: $0, options: [.mappedIfSafe]) }
        let raw = data.flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (repository, validatedPatchVersion(raw) ?? validatedGameVersion(raw))
    })
}

public func officialPatchPlan(
    patches: [OfficialPatch],
    current: [PatchRepository: String],
    requestedBaseVersion: String? = nil
) throws -> OfficialPatchPlan {
    var selected: [OfficialPatch] = []
    var latest: [PatchRepository: String] = [:]
    for repository in PatchRepository.allCases {
        let entries = patches.filter { $0.repository == repository }
        guard let last = entries.last else {
            // The official endpoint returns an empty body for a current base
            // version (X-Patch-Length: 0), while still listing expansion
            // history. Treat that as "base is current", not malformed data.
            // An empty expansion list is likewise a valid no-patch response.
            latest[repository] = repository == .game
                ? (requestedBaseVersion ?? current[repository] ?? "-")
                : (current[repository] ?? "-")
            continue
        }
        latest[repository] = last.version
        guard let local = current[repository], local != "-", PatchVersionKey(local) != nil else { continue }
        if let exact = entries.firstIndex(where: { $0.version == local }) {
            selected.append(contentsOf: entries.dropFirst(exact + 1))
            continue
        }

        // The Actoz endpoint omits a no-op/current line for some repositories.
        // Accept only the unambiguous gap where every earlier patch is older
        // than the local version; otherwise fail closed instead of guessing a
        // patch base.
        guard let next = entries.firstIndex(where: { patchVersionCompare($0.version, local) == .orderedDescending }),
              entries[..<next].allSatisfy({ patchVersionCompare($0.version, local) != .orderedDescending }) else {
            if entries.allSatisfy({ patchVersionCompare($0.version, local) != .orderedDescending }) { continue }
            throw LauncherError.manifest("현재 \(repository.rawValue) 버전에 맞는 패치 경로를 찾지 못했습니다.")
        }
        selected.append(contentsOf: entries[next...])
    }
    return OfficialPatchPlan(patches: selected, current: current, latest: latest)
}

public func fetchOfficialPatchPlan(
    at gameRoot: URL,
    fetcher: @escaping PatchMetadataFetcher = officialPatchMetadataFetcher
) async throws -> OfficialPatchPlan {
    let current = readPatchRepositoryVersions(at: gameRoot)
    let base = current[.game] ?? "-"
    guard base != "-" else {
        return OfficialPatchPlan(patches: [], current: current, latest: [:])
    }
    let patches = try await fetchOfficialPatchList(baseVersion: base, fetcher: fetcher)
    return try officialPatchPlan(patches: patches, current: current, requestedBaseVersion: base)
}

private func patchFileURL(_ patch: OfficialPatch, at cacheRoot: URL) throws -> URL {
    guard let name = patch.url.path.split(separator: "/").last.map(String.init),
          officialPatchFilenameMatches(name, version: patch.version) else {
        throw LauncherError.path("패치 파일 이름이 올바르지 않습니다.")
    }
    let directory = cacheRoot.appendingPathComponent(patch.repository.rawValue, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(name, isDirectory: false)
}

private struct SHA1BlockAccumulator {
    private var digest = Insecure.SHA1()

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        digest.update(bufferPointer: bytes)
    }

    func finalize() -> String {
        digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private func sha1Blocks(at url: URL, size: Int64, blockSize: Int64) throws -> [String] {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw LauncherError.checksum("패치 파일을 읽을 수 없습니다.") }
    defer { _ = Darwin.close(descriptor) }
    var buffer = [UInt8](repeating: 0, count: downloadChunkSize)
    var remainingFile = size
    var blockRemaining = blockSize
    var block = SHA1BlockAccumulator()
    var output: [String] = []
    buffer.withUnsafeMutableBytes { rawBuffer in
        while remainingFile > 0 {
            let readLength = min(Int64(rawBuffer.count), min(remainingFile, blockRemaining))
            let count = Darwin.read(descriptor, rawBuffer.baseAddress, Int(readLength))
            if count <= 0 { break }
            block.update(UnsafeRawBufferPointer(start: rawBuffer.baseAddress, count: count))
            remainingFile -= Int64(count)
            blockRemaining -= Int64(count)
            if blockRemaining == 0 {
                output.append(block.finalize())
                block = SHA1BlockAccumulator()
                blockRemaining = min(blockSize, remainingFile)
            }
        }
    }
    if remainingFile != 0 { throw LauncherError.checksum("패치 파일 크기가 다릅니다.") }
    if blockRemaining > 0 && blockRemaining < blockSize { output.append(block.finalize()) }
    return output
}

private func truncateFile(_ url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 0)
    try handle.close()
}

private func downloadPatchFile(
    _ patch: OfficialPatch,
    at cacheRoot: URL,
    fetcher: @escaping DownloadFetcher,
    isCancelled: @escaping @Sendable () -> Bool,
    onProgress: ((Int64) -> Void)?
) async throws -> URL {
    let final = try patchFileURL(patch, at: cacheRoot)
    let partial = final.appendingPathExtension("part")

    if let attributes = try? FileManager.default.attributesOfItem(atPath: final.path),
       let size = (attributes[.size] as? NSNumber)?.int64Value, size == patch.size,
       (try? sha1Blocks(at: final, size: patch.size, blockSize: patch.blockSize)) == patch.sha1Blocks {
        onProgress?(patch.size)
        return final
    }
    if FileManager.default.fileExists(atPath: final.path) { try? FileManager.default.removeItem(at: final) }

    var partialSize: Int64 = 0
    if let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path),
       let size = attributes[.size] as? NSNumber { partialSize = size.int64Value }
    if partialSize > patch.size {
        try truncateFile(partial)
        partialSize = 0
    }

    let requestURL = patch.url
    var append = partialSize > 0
    var response: DownloadResponse
    if append {
        do {
            response = try await fetcher(patchMakeRequest(url: requestURL, range: partialSize))
            let range = patchRangeStart(response)
            let length = patchHeader(response, "content-length").flatMap(Int64.init)
            let valid = response.statusCode == 206 &&
                range?.start == partialSize && range?.total == patch.size &&
                (length == nil || length == patch.size - partialSize)
            if !valid {
                append = false
                partialSize = 0
                response = try await fetcher(patchMakeRequest(url: requestURL, range: nil))
            }
        } catch is CancellationError {
            throw LauncherError.cancelled
        } catch let error as LauncherError where error == .cancelled {
            throw error
        } catch {
            append = false
            partialSize = 0
            response = try await fetcher(patchMakeRequest(url: requestURL, range: nil))
        }
    } else {
        response = try await fetcher(patchMakeRequest(url: requestURL, range: nil))
    }
    guard response.statusCode == (append ? 206 : 200) else {
        throw LauncherError.network("패치를 다운로드하지 못했습니다. (HTTP \(response.statusCode))")
    }

    let handle: FileHandle
    do {
        if append {
            handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            handle = try FileHandle(forWritingTo: partial)
            try handle.truncate(atOffset: 0)
        }
    } catch { throw LauncherError.network("패치 임시 파일을 열 수 없습니다.") }
    var downloaded = append ? partialSize : 0
    do {
        for try await chunk in response.body {
            if isCancelled() { throw LauncherError.cancelled }
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
            downloaded += Int64(chunk.count)
            onProgress?(downloaded)
        }
        try handle.close()
    } catch is CancellationError {
        try? handle.close()
        throw LauncherError.cancelled
    } catch {
        try? handle.close()
        throw error
    }

    guard let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path),
          let actualSize = (attributes[.size] as? NSNumber)?.int64Value,
          actualSize == patch.size else {
        throw LauncherError.checksum("패치 파일 크기가 다릅니다.")
    }
    guard (try? sha1Blocks(at: partial, size: patch.size, blockSize: patch.blockSize)) == patch.sha1Blocks else {
        try? FileManager.default.removeItem(at: partial)
        throw LauncherError.checksum("패치 파일 SHA1이 다릅니다.")
    }
    if FileManager.default.fileExists(atPath: final.path) { try? FileManager.default.removeItem(at: final) }
    try FileManager.default.moveItem(at: partial, to: final)
    return final
}

public typealias ZipatchApplier = @Sendable (URL, URL) throws -> Void

public struct ZipatchHelper: Sendable {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public var isUsable: Bool {
        FileManager.default.isExecutableFile(atPath: executable.path)
    }

    public func apply(patch: URL, gameRoot: URL) throws {
        guard isUsable, patch.isFileURL, gameRoot.isFileURL else {
            throw LauncherError.runtime("ZiPatch 도구를 사용할 수 없습니다.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["apply", patch.path, gameRoot.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LauncherError.runtime("ZiPatch 도구를 실행하지 못했습니다.")
        }
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw LauncherError.runtime("ZiPatch 적용에 실패했습니다. (종료 코드 \(process.terminationStatus))")
        }
    }
}

private func writeVersionAtomically(_ version: String, to url: URL) throws {
    guard validatedPatchVersion(version) != nil else {
        throw LauncherError.manifest("패치가 반환한 버전이 올바르지 않습니다.")
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporary = url.appendingPathExtension("part.\(UUID().uuidString)")
    try Data(version.utf8).write(to: temporary, options: [.atomic])
    if FileManager.default.fileExists(atPath: url.path) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } else {
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}

private func updateRepositoryVersion(_ repository: PatchRepository, _ version: String, at gameRoot: URL) throws {
    let ver = try repository.versionURL(at: gameRoot)
    let bck = ver.deletingPathExtension().appendingPathExtension("bck")
    // Both files receive the new checkpoint only after the helper returns
    // success. Each replacement is atomic; APFS has no cross-file transaction,
    // so this minimizes the window in which the two checkpoint files differ.
    try writeVersionAtomically(version, to: bck)
    try writeVersionAtomically(version, to: ver)
}

public func applyOfficialPatchPlan(
    _ plan: OfficialPatchPlan,
    at gameRoot: URL,
    cacheRoot: URL? = nil,
    fetcher: @escaping DownloadFetcher = urlSessionFetcher,
    applier: @escaping ZipatchApplier,
    onProgress: ((InstallProgress) -> Void)? = nil,
    isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
) async throws -> GameVersions {
    guard !plan.patches.isEmpty else {
        let current = readGameVersion(at: gameRoot)
        return GameVersions(current: current, latest: plan.latestGameVersion)
    }
    let cache = cacheRoot ?? gameRoot.appendingPathComponent(".xiv-patches", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let totalSize = plan.patches.reduce(Int64(0)) { $0 + $1.size }
    var downloadedTotal: Int64 = 0
    for (index, patch) in plan.patches.enumerated() {
        if isCancelled() { throw LauncherError.cancelled }
        var downloadedURL: URL?
        var lastError: Error?
        for _ in 0..<3 {
            do {
                downloadedURL = try await downloadPatchFile(patch, at: cache, fetcher: fetcher, isCancelled: isCancelled) { downloaded in
                    onProgress?(InstallProgress(
                        index: index,
                        total: plan.patches.count,
                        name: patch.url.lastPathComponent,
                        downloaded: downloaded,
                        fileSize: patch.size,
                        downloadedTotal: downloadedTotal + downloaded,
                        totalSize: totalSize
                    ))
                }
                lastError = nil
                break
            } catch is CancellationError {
                throw LauncherError.cancelled
            } catch let error as LauncherError where error == .cancelled {
                throw error
            } catch { lastError = error }
        }
        if let lastError { throw lastError }
        guard let patchURL = downloadedURL else {
            throw LauncherError.path("패치 파일 경로를 확인하지 못했습니다.")
        }
        downloadedTotal += patch.size
        onProgress?(InstallProgress(index: index, total: plan.patches.count, name: patch.url.lastPathComponent, downloaded: patch.size, fileSize: patch.size, downloadedTotal: downloadedTotal, totalSize: totalSize))
        if isCancelled() { throw LauncherError.cancelled }
        try applier(patchURL, gameRoot)
        // History patches may carry H...a/H...b chunk labels, which are not
        // valid game version-file contents. Only a numeric checkpoint patch
        // advances .ver/.bck after a successful apply.
        if validatedGameVersion(patch.version) != "-" {
            try updateRepositoryVersion(patch.repository, patch.version, at: gameRoot)
        }
        try? FileManager.default.removeItem(at: patchURL)
    }
    let current = readGameVersion(at: gameRoot)
    return GameVersions(current: current, latest: plan.latestGameVersion)
}
