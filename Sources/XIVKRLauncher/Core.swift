import CryptoKit
import Darwin
import Foundation
import os

/// Launch diagnostics intentionally contain only stable, non-secret facts.
///
/// The login token is never passed to this type.  Process output is redacted
/// before it reaches the logger, and launch arguments are represented by their
/// safe switches/values rather than the raw command line.
private enum CoreLaunchDiagnostics {
    private static let logger = Logger(subsystem: "land.jiyu.xivkrlauncher", category: "launch")

    static func info(_ event: String, details: [String: String] = [:], lifecycle: LauncherLogEvent? = nil) {
        if let lifecycle { LauncherLog.shared.record(lifecycle) }
        logger.info("\(render(event, details: details), privacy: .public)")
    }

    static func error(_ event: String, details: [String: String] = [:], lifecycle: LauncherLogEvent? = nil) {
        if let lifecycle { LauncherLog.shared.record(lifecycle) }
        logger.error("\(render(event, details: details), privacy: .public)")
    }

    static func sanitizedOutput(_ data: Data, token: String) -> String {
        sanitizedText(String(decoding: data, as: UTF8.self), token: token)
    }

    static func sanitizedText(_ rawValue: String, token: String) -> String {
        var value = rawValue.replacingOccurrences(of: token, with: "<redacted>")
        // Avoid control characters making the unified log look like another
        // structured message. Keep line breaks/tabs for useful diagnostics.
        value = String(value.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar.value >= 0x20
        }.map(Character.init))
        if value.count > 4_096 {
            value = String(value.prefix(4_096)) + "…"
        }
        return value
    }

    private static func render(_ event: String, details: [String: String]) -> String {
        guard !details.isEmpty else { return event }
        let suffix = details.keys.sorted().compactMap { key in
            guard let value = details[key] else { return nil }
            return "\(key)=\(value)"
        }.joined(separator: " ")
        return suffix.isEmpty ? event : "\(event) \(suffix)"
    }
}

/// Keeps a small suffix between pipe callbacks so a token split across two
/// chunks is still redacted before either half is logged.
private final class ProcessOutputRedactor: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func consume(_ data: Data, token: String, final: Bool = false) -> String {
        lock.lock()
        defer { lock.unlock() }
        pending.append(String(decoding: data, as: UTF8.self))
        if final {
            let output = pending
            pending = ""
            return CoreLaunchDiagnostics.sanitizedText(output, token: token)
        }
        let keep = max(token.count - 1, 0)
        guard pending.count > keep else { return "" }
        let split = pending.index(pending.endIndex, offsetBy: -keep)
        let output = String(pending[..<split])
        pending = String(pending[split...])
        return CoreLaunchDiagnostics.sanitizedText(output, token: token)
    }
}

public enum LauncherError: Error, LocalizedError, Equatable, Sendable {
    case manifest(String)
    case path(String)
    case network(String)
    case checksum(String)
    case cancelled
    case runtime(String)
    case authentication(String)

    public var errorDescription: String? {
        switch self {
        case .manifest(let message), .path(let message), .network(let message),
             .checksum(let message), .runtime(let message),
             .authentication(let message): return message
        case .cancelled: return "작업이 취소되었습니다."
        }
    }
}

public let manifestURL = URL(string: "https://fcdp.ff14.co.kr/FileListGame.json")!
public let bottleName = "FFXIV KR"
public let gameRelativePath = "drive_c/Program Files/FINAL FANTASY XIV - KOREA/game"
public let freshInstallFreeBytes: Int64 = 140_000_000_000
public let runtimeDownloadURL = URL(string: "https://softwareupdate.xivmac.com/sites/default/files/update_data/XIV%20on%20Mac5.4.2.tar.xz")!
public let runtimeDownloadSHA256 = "68e50be2596b6021a8e6d0e2c3c4e74c1064222697c7026e4565427813f7648f"

/// The version shown by the official launcher is stored in the game's tiny
/// `ffxivgame.ver` file. Keep this value as data rather than deriving it from
/// the manifest file count: the manifest is an install/update source, while
/// this is the version the game client actually reports.
public struct GameVersions: Equatable, Sendable {
    public let current: String
    public let latest: String

    public init(current: String, latest: String) {
        self.current = validatedGameVersion(current)
        self.latest = validatedGameVersion(latest)
    }

    /// The status values consumed by the official launcher's AppGameStatus
    /// callback are deliberately kept here with the version data.  `0` means
    /// no usable client is installed, `1` means patch/update, and `2` means
    /// the client can start.
    public func launcherStatus(installed: Bool) -> String {
        guard installed, current != "-" else { return "0" }
        guard latest != "-", current == latest else { return "1" }
        return "2"
    }

    public func appGameStatusArgument(installed: Bool) -> String {
        "\(launcherStatus(installed: installed));\(current);\(latest)"
    }
}

/// Version state used before the official page decides whether to call its
/// ExecutePatch callback.  The local value comes from the installed
/// `ffxivgame.ver`; the remote value comes from the same file in the official
/// manifest, not from FileListGame.json's top-level `Version` metadata.
public struct GameVersionStatus: Equatable, Sendable {
    public let versions: GameVersions
    public let installed: Bool
    /// Incremental repository patches can be pending even when the base
    /// `ffxivgame.ver` equals the base repository's latest value. Keep that
    /// fact alongside the two display versions so the official page does not
    /// start an out-of-date client.
    public let updateRequired: Bool?

    public init(current: String, latest: String, installed: Bool, updateRequired: Bool? = nil) {
        self.versions = GameVersions(current: current, latest: latest)
        self.installed = installed
        self.updateRequired = updateRequired
    }

    public init(versions: GameVersions, installed: Bool, updateRequired: Bool? = nil) {
        self.versions = versions
        self.installed = installed
        self.updateRequired = updateRequired
    }

    public var current: String { versions.current }
    public var latest: String { versions.latest }
    public var launcherStatus: String {
        guard installed, current != "-" else { return "0" }
        if let updateRequired { return updateRequired ? "1" : "2" }
        return versions.launcherStatus(installed: installed)
    }
    public var appGameStatusArgument: String {
        "\(launcherStatus);\(current);\(latest)"
    }
}

/// Accept only the numeric dotted version format used by `ffxivgame.ver`.
/// Returning `-` for malformed or missing data keeps an unexpected file from
/// becoming JavaScript or launcher UI input.
public func validatedGameVersion(_ raw: String) -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.count > 0, value.count <= 64,
          value.first != ".", value.last != ".",
          !value.contains(".."),
          value.unicodeScalars.allSatisfy({ ($0.value >= 48 && $0.value <= 57) || $0.value == 46 }),
          value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else {
        return "-"
    }
    return value
}

/// Read the local game version without scanning any game-sized data. The
/// Korean client currently writes a 20-byte value such as
/// `2026.05.25.0000.0000`.
public func readGameVersion(at gameRoot: URL) -> String {
    let versionURL = gameRoot.appendingPathComponent("ffxivgame.ver", isDirectory: false)
    guard let data = try? Data(contentsOf: versionURL, options: [.mappedIfSafe]),
          data.count <= 128,
          let raw = String(data: data, encoding: .utf8) else {
        return "-"
    }
    return validatedGameVersion(raw)
}

public struct ManifestFile: Codable, Hashable, Sendable {
    public let name: String
    public let size: Int64
    public let md5: String

    public init(name: String, size: Int64, md5: String) throws {
        self.name = try safeRelativePath(name)
        guard size >= 0 else { throw LauncherError.manifest("파일 크기가 올바르지 않습니다.") }
        guard md5.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil else {
            throw LauncherError.manifest("MD5가 올바르지 않습니다.")
        }
        self.size = size
        self.md5 = md5.lowercased()
    }

    private enum CodingKeys: String, CodingKey { case name, size, md5 }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(size, forKey: .size)
        try container.encode(md5, forKey: .md5)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            name: container.decode(String.self, forKey: .name),
            size: container.decode(Int64.self, forKey: .size),
            md5: container.decode(String.self, forKey: .md5)
        )
    }
}

public struct Manifest: Codable, Sendable {
    public let url: URL
    public let files: [ManifestFile]

    public init(url: URL, files: [ManifestFile]) throws {
        self.url = try officialCDNURL(url)
        var names = Set<String>()
        for file in files where !names.insert(file.name).inserted {
            throw LauncherError.manifest("중복된 파일 경로입니다: \(file.name)")
        }
        self.files = files
    }

    private enum CodingKeys: String, CodingKey { case url, files }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url.absoluteString, forKey: .url)
        try container.encode(files, forKey: .files)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawURL = try container.decode(String.self, forKey: .url)
        let files = try container.decode([ManifestFile].self, forKey: .files)
        try self.init(url: try parseURL(rawURL), files: files)
    }

    public static func parse(data: Data, manifestLocation: URL = manifestURL) throws -> Manifest {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw LauncherError.manifest("공식 파일 목록 JSON을 읽을 수 없습니다.")
        }
        guard let dictionary = object as? [String: Any] else {
            throw LauncherError.manifest("공식 파일 목록 형식이 올바르지 않습니다.")
        }
        let rawBase = dictionary["URL"] as? String
            ?? dictionary["url"] as? String
            ?? URL(string: ".", relativeTo: manifestLocation)?.absoluteURL.absoluteString
            ?? manifestLocation.absoluteString
        let base = try parseURL(rawBase)
        guard let rawFiles = dictionary["FileList"] ?? dictionary["fileList"] ?? dictionary["files"] else {
            throw LauncherError.manifest("공식 파일 목록이 없습니다.")
        }
        guard let entries = rawFiles as? [[String: Any]] else {
            throw LauncherError.manifest("공식 파일 목록의 파일 항목이 올바르지 않습니다.")
        }
        var files: [ManifestFile] = []
        files.reserveCapacity(entries.count)
        var names = Set<String>()
        for entry in entries {
            guard let rawName = (entry["Name"] ?? entry["name"] ?? entry["FileName"] ?? entry["path"]) as? String else {
                throw LauncherError.manifest("파일 이름이 없습니다.")
            }
            let name = try safeRelativePath(rawName)
            guard let rawSize = entry["Size"] ?? entry["size"] ?? entry["FileSize"],
                  let size = safeInt64(rawSize), size >= 0 else {
                throw LauncherError.manifest("파일 크기가 올바르지 않습니다: \(name)")
            }
            guard let rawMD5 = (entry["CheckSum"] ?? entry["checksum"] ?? entry["MD5"] ?? entry["md5"] ?? entry["FileMD5"]) as? String,
                  rawMD5.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil else {
                throw LauncherError.manifest("MD5가 올바르지 않습니다: \(name)")
            }
            if entry["URL"] != nil || entry["url"] != nil || entry["DownloadURL"] != nil || entry["downloadUrl"] != nil {
                throw LauncherError.manifest("파일별 다운로드 URL은 지원하지 않습니다.")
            }
            guard names.insert(name).inserted else {
                throw LauncherError.manifest("중복된 파일 경로입니다: \(name)")
            }
            files.append(try ManifestFile(name: name, size: size, md5: rawMD5))
        }
        return try Manifest(url: base, files: files)
    }
}

private func safeInt64(_ value: Any) -> Int64? {
    if let value = value as? NSNumber {
        let number = value.doubleValue
        guard number.isFinite, number.rounded() == number, number >= 0,
              number <= Double(Int64.max) else { return nil }
        return Int64(number)
    }
    if let value = value as? String, let number = Int64(value), number >= 0 { return number }
    return nil
}

private func parseURL(_ value: String) throws -> URL {
    guard let url = URL(string: value) else { throw LauncherError.manifest("URL이 올바르지 않습니다.") }
    return try officialCDNURL(url)
}

public func officialCDNURL(_ url: URL) throws -> URL {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          url.host?.lowercased() == "fcdp.ff14.co.kr",
          url.user == nil, url.password == nil, url.port == nil || url.port == (scheme == "http" ? 80 : 443) else {
        throw LauncherError.manifest("공식 FFXIV CDN URL이 아닙니다.")
    }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.scheme = "https"
    components?.port = nil
    guard let canonical = components?.url else { throw LauncherError.manifest("CDN URL이 올바르지 않습니다.") }
    return canonical
}

public func safeRelativePath(_ raw: String) throws -> String {
    guard !raw.contains("\0") else { throw LauncherError.path("파일 경로에 NUL 문자가 있습니다.") }
    // Reject encoded separators before decoding. It avoids making a URL-escaped Windows path
    // look like an ordinary POSIX path later in the pipeline.
    let encoded = raw.lowercased()
    if encoded.range(of: "%2e") != nil || encoded.range(of: "%2f") != nil || encoded.range(of: "%5c") != nil {
        throw LauncherError.path("파일 경로의 URL 인코딩이 허용되지 않습니다.")
    }
    guard !raw.contains("\\") else { throw LauncherError.path("파일 경로는 POSIX 구분자만 사용해야 합니다.") }
    guard let decoded = raw.removingPercentEncoding, !decoded.contains("\0") else {
        throw LauncherError.path("파일 경로의 URL 인코딩이 올바르지 않습니다.")
    }
    guard !decoded.contains("\\") else { throw LauncherError.path("파일 경로는 POSIX 구분자만 사용해야 합니다.") }
    guard !decoded.hasPrefix("//"), decoded.range(of: "^[A-Za-z]:", options: .regularExpression) == nil else {
        throw LauncherError.path("절대 경로는 허용되지 않습니다.")
    }
    let value = decoded.drop(while: { $0 == "/" })
    let components = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !value.isEmpty, !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
        throw LauncherError.path("파일 경로가 게임 디렉터리를 벗어납니다.")
    }
    let normalized = components.joined(separator: "/")
    guard normalized != ".", !normalized.hasPrefix("../"), !normalized.contains("/../") else {
        throw LauncherError.path("파일 경로가 게임 디렉터리를 벗어납니다.")
    }
    return normalized
}

public func fileURL(base: URL, name: String) throws -> URL {
    let base = try officialCDNURL(base)
    let path = try safeRelativePath(name)
    var result = base
    if !result.absoluteString.hasSuffix("/") { result.appendPathComponent("") }
    for component in path.split(separator: "/") {
        result.appendPathComponent(String(component), isDirectory: false)
    }
    return try officialCDNURL(result)
}

public func manifestDiff(previous: [ManifestFile], current: [ManifestFile]) -> [ManifestFile] {
    let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.name, "\($0.size):\($0.md5)") })
    return current.filter { old[$0.name] != "\($0.size):\($0.md5)" }
}

/// The checksum path must not create one `Data` object per read.  On a large
/// game file those objects can remain in an autorelease pool until the whole
/// operation returns, making the process resident size track the file size.
/// Keep one native buffer and feed CryptoKit through its buffer-pointer API.
internal let checksumBufferSize = 4 * 1024 * 1024

private struct MD5Accumulator {
    private var digest = Insecure.MD5()

    mutating func update(data: Data) {
        data.withUnsafeBytes { bytes in
            digest.update(bufferPointer: bytes)
        }
    }

    mutating func update(fileAt url: URL, byteCount: Int64? = nil) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw LauncherError.checksum("파일을 읽을 수 없습니다: \(url.lastPathComponent)")
        }
        defer { _ = Darwin.close(descriptor) }

        var buffer = [UInt8](repeating: 0, count: checksumBufferSize)
        var remaining = byteCount
        var readFailure = false
        var truncated = false

        buffer.withUnsafeMutableBytes { rawBuffer in
            while true {
                if let bytesLeft = remaining, bytesLeft == 0 { break }
                let readLength: Int
                if let bytesLeft = remaining {
                    readLength = min(rawBuffer.count, Int(bytesLeft))
                } else {
                    readLength = rawBuffer.count
                }
                let count = Darwin.read(descriptor, rawBuffer.baseAddress, readLength)
                if count == 0 {
                    truncated = remaining != nil && remaining! > 0
                    break
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    readFailure = true
                    break
                }
                digest.update(bufferPointer: UnsafeRawBufferPointer(
                    start: rawBuffer.baseAddress,
                    count: count
                ))
                if remaining != nil { remaining! -= Int64(count) }
            }
        }

        if readFailure || truncated {
            throw LauncherError.checksum("파일을 읽을 수 없습니다: \(url.lastPathComponent)")
        }
    }

    func finalize() -> String {
        digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public func md5File(at url: URL) throws -> String {
    var accumulator = MD5Accumulator()
    try accumulator.update(fileAt: url)
    return accumulator.finalize()
}

public func sha256File(at url: URL) throws -> String {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else {
        throw LauncherError.checksum("파일을 읽을 수 없습니다: \(url.lastPathComponent)")
    }
    defer { _ = Darwin.close(descriptor) }

    var digest = SHA256()
    var buffer = [UInt8](repeating: 0, count: checksumBufferSize)
    var failed = false
    buffer.withUnsafeMutableBytes { bytes in
        while true {
            let count = Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                failed = true
                break
            }
            digest.update(bufferPointer: UnsafeRawBufferPointer(start: bytes.baseAddress, count: count))
        }
    }
    guard !failed else {
        throw LauncherError.checksum("파일을 읽을 수 없습니다: \(url.lastPathComponent)")
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

public struct InstallProgress: Sendable {
    public let index: Int
    public let total: Int
    public let name: String
    public let downloaded: Int64
    public let fileSize: Int64
    public let downloadedTotal: Int64
    public let totalSize: Int64
}

public struct DownloadResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: AsyncThrowingStream<Data, Error>

    public init(statusCode: Int, headers: [String: String] = [:], body: AsyncThrowingStream<Data, Error>) {
        self.statusCode = statusCode
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

public typealias DownloadFetcher = @Sendable (URLRequest) async throws -> DownloadResponse

/// Turns an asynchronous producer into the body stream consumed by the file
/// writer. `AsyncThrowingStream` defaults to an unbounded buffer; that is a
/// dangerous default for game files because the producer can read the entire
/// response while the consumer is hashing/writing it. A small bounded queue of
/// 4-MiB-or-smaller chunks is kept ahead of the consumer, and the producer
/// waits when it is full. This is the back-pressure boundary that keeps memory
/// usage independent of file size while leaving enough in-flight data for a
/// good network throughput.
internal let downloadChunkSize = 4 * 1024 * 1024
internal let downloadChunkBufferCapacity = 8

internal func boundedDataStream(
    producer: @escaping @Sendable (
        @escaping @Sendable (Data) async throws -> Void
    ) async throws -> Void
) -> AsyncThrowingStream<Data, Error> {
    final class TaskBox: @unchecked Sendable {
        var task: Task<Void, Never>?
    }

    let taskBox = TaskBox()
    let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(downloadChunkBufferCapacity)) { continuation in
        let emit: @Sendable (Data) async throws -> Void = { chunk in
            while true {
                try Task.checkCancellation()
                switch continuation.yield(chunk) {
                case .enqueued:
                    return
                case .dropped:
                    // The bounded buffer is still occupied. Keep the same
                    // chunk and retry instead of dropping bytes.
                    try await Task.sleep(nanoseconds: 1_000_000)
                case .terminated:
                    throw CancellationError()
                @unknown default:
                    throw CancellationError()
                }
            }
        }

        let task = Task {
            do {
                try await producer(emit)
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: LauncherError.cancelled)
            } catch {
                continuation.finish(throwing: error)
            }
        }
        taskBox.task = task
        continuation.onTermination = { @Sendable _ in
            taskBox.task?.cancel()
        }
    }
    return stream
}

public let urlSessionFetcher: DownloadFetcher = { request in
    do {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let stream = boundedDataStream { emit in
            var buffer = Data()
            buffer.reserveCapacity(downloadChunkSize)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= downloadChunkSize {
                    try await emit(buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty { try await emit(buffer) }
        }
        let http = response as? HTTPURLResponse
        return DownloadResponse(statusCode: http?.statusCode ?? 0, headers: http?.allHeaderFields.reduce(into: [:]) { result, item in
            result[String(describing: item.key).lowercased()] = String(describing: item.value)
        } ?? [:], body: stream)
    } catch is CancellationError {
        throw LauncherError.cancelled
    } catch {
        throw error
    }
}

/// Read the tiny version file from the official CDN.  FileListGame.json's
/// `Version` field is a file-list/maintenance identifier (for example
/// `2026.06.02.01`), while the launcher and game compare the dotted version
/// written in `ffxivgame.ver` (for example
/// `2026.05.25.0000.0000`).  Do not use the former as the game version.
public func fetchLatestGameVersion(
    from manifest: Manifest,
    fetcher: @escaping DownloadFetcher = urlSessionFetcher
) async throws -> String {
    guard let versionFile = manifest.files.first(where: {
        $0.name.caseInsensitiveCompare("ffxivgame.ver") == .orderedSame
    }) else {
        throw LauncherError.manifest("공식 파일 목록에 ffxivgame.ver가 없습니다.")
    }
    let request = makeRequest(
        url: try fileURL(base: manifest.url, name: versionFile.name),
        range: nil
    )
    let response: DownloadResponse
    do {
        response = try await fetcher(request)
    } catch is CancellationError {
        throw LauncherError.cancelled
    } catch let error as LauncherError {
        throw error
    } catch {
        throw LauncherError.network("최신 게임 버전을 확인하지 못했습니다.")
    }
    guard (200..<300).contains(response.statusCode) else {
        throw LauncherError.network("최신 게임 버전을 확인하지 못했습니다. (HTTP \(response.statusCode))")
    }

    // This file is currently 20 bytes.  Keep the cap independent of the
    // manifest so a malformed server response cannot turn a version check
    // into an unbounded in-memory download.
    let maxVersionBytes = 128
    var data = Data()
    data.reserveCapacity(min(maxVersionBytes, max(0, Int(versionFile.size))))
    do {
        for try await chunk in response.body {
            guard data.count + chunk.count <= maxVersionBytes else {
                throw LauncherError.manifest("공식 게임 버전 파일이 너무 큽니다.")
            }
            data.append(chunk)
        }
    } catch is CancellationError {
        throw LauncherError.cancelled
    } catch let error as LauncherError {
        throw error
    } catch {
        throw LauncherError.network("최신 게임 버전을 확인하지 못했습니다.")
    }
    guard Int64(data.count) == versionFile.size else {
        throw LauncherError.checksum("공식 게임 버전 파일 크기가 다릅니다.")
    }
    var digest = MD5Accumulator()
    digest.update(data: data)
    guard digest.finalize() == versionFile.md5 else {
        throw LauncherError.checksum("공식 게임 버전 파일 MD5가 다릅니다.")
    }
    guard let raw = String(data: data, encoding: .utf8) else {
        throw LauncherError.manifest("공식 게임 버전 파일을 읽을 수 없습니다.")
    }
    let version = validatedGameVersion(raw)
    guard version != "-" else {
        throw LauncherError.manifest("공식 게임 버전 형식이 올바르지 않습니다.")
    }
    return version
}

private func header(_ response: DownloadResponse, _ name: String) -> String? {
    response.headers[name.lowercased()]
}

private func rangeStart(_ response: DownloadResponse) -> (start: Int64, end: Int64, total: Int64?)? {
    guard let value = header(response, "content-range") else { return nil }
    let pattern = #"^bytes\s+(\d+)-(\d+)/(\d+|\*)$"#
    guard let match = value.range(of: pattern, options: .regularExpression) else { return nil }
    let fields = value[match].split { $0 == " " || $0 == "-" || $0 == "/" }.map(String.init)
    guard fields.count == 4, let start = Int64(fields[1]), let end = Int64(fields[2]) else { return nil }
    let total = fields[3] == "*" ? nil : Int64(fields[3])
    return (start, end, total)
}

private func makeRequest(url: URL, range: Int64?) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    if let range { request.setValue("bytes=\(range)-", forHTTPHeaderField: "Range") }
    return request
}

private func finalURL(root: URL, name: String) throws -> URL {
    let relative = try safeRelativePath(name)
    let target = root.appendingPathComponent(relative)
    let rootPath = root.standardizedFileURL.path
    let targetPath = target.standardizedFileURL.path
    guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
        throw LauncherError.path("파일 경로가 게임 디렉터리를 벗어납니다.")
    }
    return target
}

private func downloadOne(
    _ file: ManifestFile,
    baseURL: URL,
    root: URL,
    fetcher: @escaping DownloadFetcher,
    isCancelled: @escaping @Sendable () -> Bool,
    onProgress: ((Int64) -> Void)?
) async throws {
    let final = try finalURL(root: root, name: file.name)
    let partial = final.appendingPathExtension("part")
    try FileManager.default.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
    var partialSize: Int64 = 0
    if let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path),
       let size = attributes[.size] as? NSNumber {
        partialSize = size.int64Value
    }
    if partialSize > file.size {
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let truncate = try FileHandle(forWritingTo: partial)
        try truncate.truncate(atOffset: 0)
        try truncate.close()
        partialSize = 0
    }
    if isCancelled() { throw LauncherError.cancelled }
    try Task.checkCancellation()
    var append = partialSize > 0
    var response: DownloadResponse
    if append {
        do {
            if isCancelled() { throw LauncherError.cancelled }
            response = try await fetcher(makeRequest(url: try fileURL(base: baseURL, name: file.name), range: partialSize))
            let range = rangeStart(response)
            let contentLength = header(response, "content-length").flatMap(Int64.init)
            let validRange = response.statusCode == 206 &&
                range.map { $0.start == partialSize && $0.end >= $0.start && ($0.total == nil || $0.total == file.size) } == true &&
                (contentLength == nil || contentLength == file.size - partialSize)
            if !validRange {
                append = false
                partialSize = 0
                if isCancelled() { throw LauncherError.cancelled }
                response = try await fetcher(makeRequest(url: try fileURL(base: baseURL, name: file.name), range: nil))
            }
        } catch is CancellationError {
            throw LauncherError.cancelled
        } catch let error as LauncherError where error == .cancelled {
            throw error
        } catch {
            // A broken Range request must fall back to a fresh response. Retrying the same
            // Range forever leaves a valid-looking .part file unusable.
            append = false
            partialSize = 0
            if isCancelled() { throw LauncherError.cancelled }
            response = try await fetcher(makeRequest(url: try fileURL(base: baseURL, name: file.name), range: nil))
        }
    } else {
        do {
            if isCancelled() { throw LauncherError.cancelled }
            response = try await fetcher(makeRequest(url: try fileURL(base: baseURL, name: file.name), range: nil))
        }
        catch is CancellationError { throw LauncherError.cancelled }
    }
    guard response.statusCode == (append ? 206 : 200) else {
        throw LauncherError.network("파일을 다운로드하지 못했습니다: \(file.name) (HTTP \(response.statusCode))")
    }
    var digest = MD5Accumulator()
    if append && partialSize > 0 {
        // The resumed prefix is hashed with the same fixed-size reader, then
        // the incoming body continues the same digest state below.
        try digest.update(fileAt: partial, byteCount: partialSize)
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
    } catch { throw LauncherError.network("임시 파일을 열 수 없습니다: \(file.name)") }
    var downloaded = append ? partialSize : 0
    do {
        for try await chunk in response.body {
            if isCancelled() { throw LauncherError.cancelled }
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
            digest.update(data: chunk)
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
    let attributes = try FileManager.default.attributesOfItem(atPath: partial.path)
    let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
    guard actualSize == file.size else { throw LauncherError.checksum("파일 크기가 다릅니다: \(file.name)") }
    guard digest.finalize() == file.md5 else { throw LauncherError.checksum("파일 MD5가 다릅니다: \(file.name)") }
    if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
    try FileManager.default.moveItem(at: partial, to: final)
}

public func hasUsableManifestState(at root: URL) -> Bool {
    guard let data = try? Data(contentsOf: root.appendingPathComponent(".xiv-manifest.json")),
          let manifest = try? Manifest.parse(data: data), !manifest.files.isEmpty else { return false }
    return true
}

public func hasFreshInstallDiskSpace(at url: URL, required: Int64 = freshInstallFreeBytes) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
          let available = values.volumeAvailableCapacityForImportantUsage else { return false }
    return available >= required
}

public func installManifest(
    _ manifest: Manifest,
    at root: URL,
    fetcher: @escaping DownloadFetcher = urlSessionFetcher,
    onProgress: ((InstallProgress) -> Void)? = nil,
    isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
) async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let previous: Manifest?
    if let data = try? Data(contentsOf: root.appendingPathComponent(".xiv-manifest.json")), let state = try? Manifest.parse(data: data) {
        previous = state
    } else { previous = nil }
    let manifestMatchesSaved = previous?.url == manifest.url && previous?.files == manifest.files
    let changed: Set<String>
    if manifestMatchesSaved {
        changed = []
    } else if previous == nil || previous?.url != manifest.url {
        changed = Set(manifest.files.map(\.name))
    } else {
        changed = Set(manifestDiff(previous: previous?.files ?? [], current: manifest.files).map(\.name))
    }
    let totalSize = manifest.files.reduce(Int64(0)) { $0 + $1.size }
    var downloadedTotal: Int64 = 0
    for (index, file) in manifest.files.enumerated() {
        if isCancelled() { throw LauncherError.cancelled }
        let final = try finalURL(root: root, name: file.name)
        let attributes = try? FileManager.default.attributesOfItem(atPath: final.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value
        // The successful saved manifest is the version/checksum authority.
        // Re-hashing every unchanged file on every launch makes RSS grow with
        // the game size on some Foundation runtimes.  A missing/truncated
        // file is still repaired, while an unchanged file is accepted without
        // another full read.  A changed manifest only processes changed/new
        // entries; unchanged entries remain trusted from the prior state.
        if !changed.contains(file.name), size == file.size {
            downloadedTotal += file.size
            onProgress?(InstallProgress(index: index, total: manifest.files.count, name: file.name, downloaded: file.size, fileSize: file.size, downloadedTotal: downloadedTotal, totalSize: totalSize))
            continue
        }
        var lastError: Error?
        for _ in 0..<3 {
            do {
                try await downloadOne(file, baseURL: manifest.url, root: root, fetcher: fetcher, isCancelled: isCancelled) { downloaded in
                    onProgress?(InstallProgress(index: index, total: manifest.files.count, name: file.name, downloaded: downloaded, fileSize: file.size, downloadedTotal: downloadedTotal + downloaded, totalSize: totalSize))
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
        downloadedTotal += file.size
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let state = try encoder.encode(manifest)
    let temporary = root.appendingPathComponent(".xiv-manifest.json.part")
    try state.write(to: temporary, options: .atomic)
    let destination = root.appendingPathComponent(".xiv-manifest.json")
    if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
    } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

public struct LaunchProfile: Sendable, Equatable {
    public let lobbyHost: String
    public let lobbyPort: Int
    public let gmHost: String
    public let saveDataHost: String

    public static let `default` = LaunchProfile(
        lobbyHost: "nlobbyf-live.ff14.co.kr",
        lobbyPort: 54994,
        gmHost: "ngm-live.ff14.co.kr",
        saveDataHost: "nconfig-dl-live.ff14.co.kr"
    )
}

public func validateToken(_ token: String) throws -> String {
    guard token.range(of: "^[A-Za-z0-9+/=]{40,64}$", options: .regularExpression) != nil else {
        throw LauncherError.authentication("서버가 올바르지 않은 게임 토큰을 반환했습니다.")
    }
    return token
}

public func buildLaunchArguments(token: String, profile: LaunchProfile = .default) throws -> [String] {
    let token = try validateToken(token)
    return [
        "DEV.LobbyHost01=\(profile.lobbyHost)",
        "DEV.LobbyPort01=\(profile.lobbyPort)",
        "DEV.GMServerHost=\(profile.gmHost)",
        "DEV.TestSID=\(token)",
        "SYS.resetConfig=0",
        "DEV.SaveDataBankHost=\(profile.saveDataHost)"
    ]
}

public func buildWineArguments(token: String, executable: String = "ffxiv_dx11.exe") throws -> [String] {
    guard !executable.isEmpty, !executable.contains("\0") else {
        throw LauncherError.runtime("게임 실행 파일 경로가 올바르지 않습니다.")
    }
    return [executable] + (try buildLaunchArguments(token: token))
}

private func redactedWineArguments(_ arguments: [String]) -> [String] {
    arguments.map { argument in
        if argument.hasPrefix("DEV.TestSID=") { return "DEV.TestSID=<redacted>" }
        return argument
    }
}

public struct WineRuntime: Sendable {
    public let base: URL
    public let root: URL
    public let wine: URL
    public let d3dcompiler: URL

    public init(baseURL: URL) {
        self.base = baseURL
        self.root = baseURL.appendingPathComponent("wine", isDirectory: true)
        self.wine = root.appendingPathComponent("bin/wine")
        self.d3dcompiler = baseURL.appendingPathComponent("d3dcompiler/d3dcompiler_47.dll")
    }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: wine.path) &&
            FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/wine").path) &&
            FileManager.default.fileExists(atPath: d3dcompiler.path)
    }

    public func environment(prefixURL: URL, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let bin = root.appendingPathComponent("bin").path
        environment["PATH"] = bin + ":" + (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        environment["WINEPREFIX"] = prefixURL.path
        environment["WINEARCH"] = "win64"
        environment["WINEDLLPATH"] = root.appendingPathComponent("lib/wine").path
        environment["WINEMSYNC"] = "1"
        environment["DXMT_ENABLE_NVEXT"] = "1"
        environment["WINEDLLOVERRIDES"] = "d3dcompiler_47=n,b"
        environment["WINEDEBUG"] = "-all"
        environment["LANG"] = "en_US"
        environment["MVK_CONFIG_LOG_LEVEL"] = "mvk_error"
        environment["DOTNET_EnableWriteXorExecute"] = "0"
        return environment
    }
}

public func installRuntimeArchive(
    _ archiveURL: URL,
    expectedSHA256: String,
    runtime: WineRuntime,
    fileManager: FileManager = .default
) async throws {
    guard try sha256File(at: archiveURL) == expectedSHA256.lowercased() else {
        throw LauncherError.checksum("Wine 런타임 파일 검증에 실패했습니다.")
    }

    let parent = runtime.base.deletingLastPathComponent()
    let staging = parent.appendingPathComponent(".runtime-install-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: staging) }

    let status = try await runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/tar"),
        arguments: [
            "-xf", archiveURL.path, "-C", staging.path,
            "XIV on Mac.app/Contents/Resources/wine",
            "XIV on Mac.app/Contents/Resources/d3dcompiler"
        ]
    )
    let resources = staging.appendingPathComponent("XIV on Mac.app/Contents/Resources", isDirectory: true)
    let extracted = WineRuntime(baseURL: resources)
    guard status == 0, extracted.isInstalled else {
        throw LauncherError.runtime("Wine 런타임 압축을 풀지 못했습니다.")
    }

    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: runtime.base.path) {
        try fileManager.removeItem(at: runtime.base)
    }
    try fileManager.createDirectory(at: runtime.base, withIntermediateDirectories: false)
    try fileManager.moveItem(at: extracted.root, to: runtime.root)
    try fileManager.moveItem(
        at: extracted.d3dcompiler.deletingLastPathComponent(),
        to: runtime.d3dcompiler.deletingLastPathComponent()
    )
}

private func runProcess(
    executable: URL,
    arguments: [String],
    environment: [String: String]? = nil
) async throws -> Int32 {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do { try process.run() }
        catch { continuation.resume(throwing: error) }
    }
}

public func standalonePrefixURL(homeURL: URL) -> URL {
    homeURL.appendingPathComponent("Library/Application Support/XIV KR Launcher/wineprefix", isDirectory: true)
}

/// The native shell's deliberately small implementation boundary. It keeps
/// Wine, manifest, and token handling out of AppKit and is intentionally
/// concrete rather than split into speculative services.
final class LauncherCore: LauncherCoreAPI {
    private let fileManager: FileManager
    private let runtime: WineRuntime
    private let prefixURL: URL
    private let gameURL: URL
    private let runningGameProcess = RunningProcessStore()
    private let cancellation = CancellationFlag()

    let windowsGamePath = #"C:\Program Files\FINAL FANTASY XIV - KOREA\game"#

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let home = fileManager.homeDirectoryForCurrentUser
        self.runtime = WineRuntime(baseURL: home.appendingPathComponent(
            "Library/Application Support/XIV KR Launcher/runtime/current",
            isDirectory: true
        ))
        let prefix = standalonePrefixURL(homeURL: home)
        self.prefixURL = prefix
        self.gameURL = prefix.appendingPathComponent(gameRelativePath, isDirectory: true)
    }

    /// Apply the official Actoz ZiPatch chain for a complete client.
    ///
    /// The full FileListGame install is only a bootstrap: its version files
    /// can describe an older client than the live game servers.  Always read
    /// those files again after a bootstrap and ask the patch endpoint for the
    /// pending chain.  Keeping this in one method makes the existing-client
    /// and post-manifest paths use exactly the same version/helper checks.
    private func applyPendingOfficialPatches(
        progress: @escaping @Sendable (LauncherProgress) -> Void
    ) async throws -> GameVersions {
        let repositoryVersions = readPatchRepositoryVersions(at: gameURL)
        let hasCompleteVersionSet = PatchRepository.allCases.allSatisfy {
            repositoryVersions[$0] != "-"
        }
        guard hasCompleteVersionSet else {
            throw LauncherError.manifest("설치된 한국 클라이언트 버전 파일을 확인할 수 없습니다.")
        }

        let executable = gameURL.appendingPathComponent("ffxiv_dx11.exe")
        let executableIsRegular = (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        guard fileManager.fileExists(atPath: executable.path), executableIsRegular else {
            throw LauncherError.manifest("설치된 한국 클라이언트 실행 파일을 확인할 수 없습니다.")
        }

        try cancellation.check()
        let plan = try await fetchOfficialPatchPlan(at: gameURL)
        guard plan.hasUpdates else {
            return GameVersions(current: readGameVersion(at: gameURL), latest: plan.latestGameVersion)
        }

        guard let helperURL = Bundle.main.resourceURL?.appendingPathComponent("zipatch-helper"),
              FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw LauncherError.runtime("ZiPatch 도구가 앱에 포함되어 있지 않습니다. 패키징을 다시 해 주세요.")
        }
        let helper = ZipatchHelper(executable: helperURL)
        return try await applyOfficialPatchPlan(
            plan,
            at: gameURL,
            fetcher: urlSessionFetcher,
            applier: { patch, root in try helper.apply(patch: patch, gameRoot: root) },
            onProgress: { [cancellation] value in
                if cancellation.isCancelled { return }
                progress(LauncherProgress(
                    index: value.index,
                    total: value.total,
                    fileName: value.name,
                    downloaded: value.downloaded,
                    fileSize: value.fileSize,
                    downloadedTotal: value.downloadedTotal,
                    totalSize: value.totalSize
                ))
            },
            isCancelled: { [cancellation] in cancellation.isCancelled }
        )
    }

    func install(progress: @escaping @Sendable (LauncherProgress) -> Void) async throws -> GameVersions {
        cancellation.reset()
        try cancellation.check()

        // An existing Korean client must be advanced with the official
        // ZiPatch chain. FileListGame.json is a complete-file manifest and
        // cannot safely replace a patch operation against SqPack files.
        let repositoryVersions = readPatchRepositoryVersions(at: gameURL)
        let hasCompleteVersionSet = PatchRepository.allCases.allSatisfy {
            repositoryVersions[$0] != "-"
        }
        if hasCompleteVersionSet,
           fileManager.fileExists(atPath: gameURL.appendingPathComponent("ffxiv_dx11.exe").path) {
            return try await applyPendingOfficialPatches(progress: progress)
        }

        if !hasUsableManifestState(at: gameURL) && !hasFreshInstallDiskSpace(at: gameURL) {
            throw LauncherError.runtime("새로 설치하려면 140GB 이상의 여유 공간이 필요합니다.")
        }
        let manifest = try await fetchManifest()
        try await installManifest(manifest, at: gameURL, fetcher: urlSessionFetcher, onProgress: { [cancellation] value in
            if cancellation.isCancelled { return }
            progress(LauncherProgress(
                index: value.index,
                total: value.total,
                fileName: value.name,
                downloaded: value.downloaded,
                fileSize: value.fileSize,
                downloadedTotal: value.downloadedTotal,
                totalSize: value.totalSize
            ))
        }, isCancelled: { [cancellation] in cancellation.isCancelled })
        try cancellation.check()
        // A successful full-file bootstrap may still be behind the live
        // client.  Read the freshly installed version files and apply the
        // official binary patch chain before reporting ready to the web UI.
        return try await applyPendingOfficialPatches(progress: progress)
    }

    /// Perform the lightweight check needed before AppCompleteResize.  The
    /// official page starts patching immediately when it receives status `1`,
    /// so callers must not send the old `1;-;-` sentinel before this check.
    /// A missing client returns status `0`; a valid client with any pending
    /// official repository patch returns status `1`; only an exact patch-plan
    /// match across the installed repositories returns status `2`.
    func checkVersion() async throws -> GameVersionStatus {
        let executable = gameURL.appendingPathComponent("ffxiv_dx11.exe")
        let executableExists = fileManager.fileExists(atPath: executable.path)
        let local = readGameVersion(at: gameURL)
        let installed = executableExists &&
            hasUsableManifestState(at: gameURL) && local != "-"

        // There is no reason to fetch a CDN version for a fresh install. The
        // subsequent install call fetches and validates the same tiny file.
        guard installed else {
            return GameVersionStatus(current: local, latest: "-", installed: false)
        }

        let plan = try await fetchOfficialPatchPlan(at: gameURL)
        return GameVersionStatus(
            current: local,
            latest: plan.latestGameVersion,
            installed: true,
            updateRequired: plan.hasUpdates
        )
    }

    func cancelInstall() {
        cancellation.cancel()
    }

    func launch(token: String) async throws {
        try await ensureRuntime()
        try ensureExecutionRuntime()
        CoreLaunchDiagnostics.info("Wine runtime check", details: [
            "wine": runtime.isInstalled ? "managed" : "crossover"
        ])

        let prefixExists = fileManager.fileExists(atPath: prefixURL.path)
        CoreLaunchDiagnostics.info("Wine prefix check", details: [
            "state": prefixExists ? "present" : "missing"
        ])
        try await ensurePrefix()

        CoreLaunchDiagnostics.info("Wine prefix ready")
        let validatedToken: String
        do {
            validatedToken = try validateToken(token)
        } catch {
            CoreLaunchDiagnostics.error("Game token validation failed", lifecycle: .launchFailed)
            throw error
        }
        let executable = gameURL.appendingPathComponent("ffxiv_dx11.exe")
        let executableExists = fileManager.fileExists(atPath: executable.path)
        let executableIsRegular = (try? executable.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        CoreLaunchDiagnostics.info("Game executable check", details: [
            "name": executable.lastPathComponent,
            "state": executableExists && executableIsRegular ? "ready" : "missing-or-invalid"
        ])
        guard executableExists, executableIsRegular else {
            CoreLaunchDiagnostics.error("Game executable check failed", details: ["name": executable.lastPathComponent], lifecycle: .launchFailed)
            throw LauncherError.runtime("ffxiv_dx11.exe가 없습니다. 먼저 설치해 주세요.")
        }

        do {
            if let config = try findExistingFFXIVConfig(
                bottleURL: prefixURL,
                homeURL: fileManager.homeDirectoryForCurrentUser,
                fileManager: fileManager
            ) {
                let changed = try enableOpeningMovieSkip(at: config, fileManager: fileManager)
                CoreLaunchDiagnostics.info("Opening movie skip config", details: [
                    "state": changed ? "applied" : "already-enabled"
                ])
            } else {
                CoreLaunchDiagnostics.info("Opening movie skip config", details: ["state": "not-found"])
            }
        } catch {
            CoreLaunchDiagnostics.error("Opening movie skip config failed", lifecycle: .launchFailed)
            throw error
        }

        let process = Process()
        process.executableURL = runtime.wine
        let arguments = try buildWineArguments(token: validatedToken, executable: executable.path)
        process.arguments = arguments
        process.environment = runtime.environment(prefixURL: prefixURL)
        process.currentDirectoryURL = gameURL
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutRedactor = ProcessOutputRedactor()
        let stderrRedactor = ProcessOutputRedactor()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                let output = stdoutRedactor.consume(Data(), token: validatedToken, final: true)
                if !output.isEmpty {
                    CoreLaunchDiagnostics.info("Wine stdout", details: [
                        "pid": process.map { String($0.processIdentifier) } ?? "unknown",
                        "output": output
                    ])
                }
                return
            }
            let output = stdoutRedactor.consume(data, token: validatedToken)
            guard !output.isEmpty else { return }
            CoreLaunchDiagnostics.info("Wine stdout", details: [
                "pid": process.map { String($0.processIdentifier) } ?? "unknown",
                "output": output
            ])
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                let output = stderrRedactor.consume(Data(), token: validatedToken, final: true)
                if !output.isEmpty {
                    CoreLaunchDiagnostics.error("Wine stderr", details: [
                        "pid": process.map { String($0.processIdentifier) } ?? "unknown",
                        "output": output
                    ])
                }
                return
            }
            let output = stderrRedactor.consume(data, token: validatedToken)
            guard !output.isEmpty else { return }
            CoreLaunchDiagnostics.error("Wine stderr", details: [
                "pid": process.map { String($0.processIdentifier) } ?? "unknown",
                "output": output
            ])
        }
        runningGameProcess.set(process)
        process.terminationHandler = { process in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let trailingStdout = stdoutRedactor.consume(Data(), token: validatedToken, final: true)
            let trailingStderr = stderrRedactor.consume(Data(), token: validatedToken, final: true)
            if !trailingStdout.isEmpty {
                CoreLaunchDiagnostics.info("Wine stdout", details: [
                    "pid": String(process.processIdentifier),
                    "output": trailingStdout
                ])
            }
            if !trailingStderr.isEmpty {
                CoreLaunchDiagnostics.error("Wine stderr", details: [
                    "pid": String(process.processIdentifier),
                    "output": trailingStderr
                ])
            }
            self.runningGameProcess.clear(process)
            let details = [
                "pid": String(process.processIdentifier),
                "status": String(process.terminationStatus),
                "reason": String(describing: process.terminationReason)
            ]
            if process.terminationStatus == 0 {
                CoreLaunchDiagnostics.info("Wine game process exited", details: details, lifecycle: .launchSucceeded)
            } else {
                CoreLaunchDiagnostics.error("Wine game process exited with failure", details: details, lifecycle: .launchFailed)
            }
        }

        CoreLaunchDiagnostics.info("Wine launch requested", details: [
            "executable": process.executableURL?.lastPathComponent ?? "wine",
            "workingDirectory": gameURL.path,
            "arguments": redactedWineArguments(arguments).joined(separator: " ")
        ], lifecycle: .launchStarted)
        do {
            try process.run()
            CoreLaunchDiagnostics.info("Wine game process started", details: ["pid": String(process.processIdentifier)])
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            runningGameProcess.clear(process)
            CoreLaunchDiagnostics.error("Wine launch failed", details: [
                "error": CoreLaunchDiagnostics.sanitizedText(error.localizedDescription, token: validatedToken)
            ], lifecycle: .launchFailed)
            throw LauncherError.runtime("Wine에서 게임을 시작하지 못했습니다. Rosetta 2 설치 여부를 확인해 주세요.")
        }

        // A launch that exits immediately is the actionable failure users need
        // to see.  Do not wait on a normal game process or block the UI thread.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.75) { [weak process] in
            guard let process, !process.isRunning, process.terminationStatus != 0 else { return }
            CoreLaunchDiagnostics.error("Wine game process exited immediately", details: [
                "pid": String(process.processIdentifier),
                "status": String(process.terminationStatus)
            ], lifecycle: .launchFailed)
        }
    }

    private func fetchManifest() async throws -> Manifest {
        var request = URLRequest(url: manifestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw LauncherError.network("공식 파일 목록을 가져오지 못했습니다.")
            }
            return try Manifest.parse(data: data)
        } catch is CancellationError { throw LauncherError.cancelled }
        catch let error as LauncherError { throw error }
        catch { throw LauncherError.network("공식 파일 목록을 가져오지 못했습니다.") }
    }

    private func ensureExecutionRuntime() throws {
        guard runtime.isInstalled else {
            CoreLaunchDiagnostics.error("Wine runtime check failed", lifecycle: .launchFailed)
            throw LauncherError.runtime("독립 Wine 런타임이 설치되지 않았습니다.")
        }
    }

    private func ensureRuntime() async throws {
        if runtime.isInstalled { return }
        CoreLaunchDiagnostics.info("Wine runtime download requested")
        do {
            let (temporary, response) = try await URLSession.shared.download(from: runtimeDownloadURL)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  response.url?.scheme?.lowercased() == "https",
                  response.url?.host?.lowercased() == runtimeDownloadURL.host?.lowercased() else {
                throw LauncherError.network("독립 Wine 런타임을 다운로드하지 못했습니다.")
            }
            try await installRuntimeArchive(
                temporary,
                expectedSHA256: runtimeDownloadSHA256,
                runtime: runtime,
                fileManager: fileManager
            )
            CoreLaunchDiagnostics.info("Wine runtime installed")
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError.network("독립 Wine 런타임을 다운로드하지 못했습니다.")
        }
    }

    private func ensurePrefix() async throws {
        guard runtime.isInstalled else {
            throw LauncherError.runtime("독립 Wine 런타임 구성이 올바르지 않습니다.")
        }
        let driveC = prefixURL.appendingPathComponent("drive_c", isDirectory: true)
        let systemRegistry = prefixURL.appendingPathComponent("system.reg")
        try fileManager.createDirectory(at: prefixURL, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: systemRegistry.path) {
            CoreLaunchDiagnostics.info("Wine prefix creation requested")
            try await runWineTool(["wineboot", "--init"])
            try await runWineTool(["winecfg", "-v", "win10"])
            guard fileManager.fileExists(atPath: driveC.path) else {
                throw LauncherError.runtime("Wine prefix를 만들지 못했습니다.")
            }
            CoreLaunchDiagnostics.info("Wine prefix created")
        }
        try installD3DCompiler()
        try fileManager.createDirectory(at: gameURL, withIntermediateDirectories: true)
    }

    private func runWineTool(_ arguments: [String]) async throws {
        let status = try await runProcess(
            executable: runtime.wine,
            arguments: arguments,
            environment: runtime.environment(prefixURL: prefixURL)
        )
        guard status == 0 else {
            CoreLaunchDiagnostics.error("Wine prefix command failed", details: [
                "command": arguments.first ?? "unknown",
                "status": String(status)
            ])
            throw LauncherError.runtime("Wine prefix 초기화에 실패했습니다. (종료 코드 \(status))")
        }
    }

    private func installD3DCompiler() throws {
        let system32 = prefixURL.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        try fileManager.createDirectory(at: system32, withIntermediateDirectories: true)
        let destination = system32.appendingPathComponent("d3dcompiler_47.dll")
        guard !fileManager.contentsEqual(atPath: runtime.d3dcompiler.path, andPath: destination.path) else { return }
        let backup = destination.appendingPathExtension("xivkr-builtin")
        if fileManager.fileExists(atPath: destination.path) {
            if !fileManager.fileExists(atPath: backup.path) {
                try fileManager.copyItem(at: destination, to: backup)
            }
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: runtime.d3dcompiler, to: destination)
    }

}

private final class RunningProcessStore: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        lock.unlock()
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func reset() {
        lock.lock(); value = false; lock.unlock()
    }

    func cancel() {
        lock.lock(); value = true; lock.unlock()
    }

    func check() throws {
        if isCancelled { throw LauncherError.cancelled }
        try Task.checkCancellation()
    }
}
