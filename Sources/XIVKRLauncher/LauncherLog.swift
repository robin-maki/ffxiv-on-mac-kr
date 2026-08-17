import AppKit
import Foundation

enum VersionCheckFailureCategory: String, Sendable {
    case manifest, path, network, checksum, cancelled, other
}

/// The only events that may be written to the launcher log.
///
/// Deliberately do not add token, password, OTP, cookie, URL, command-line,
/// or arbitrary error-string fields here.  Callers can report what happened,
/// but never the sensitive values involved in making it happen.
enum LauncherLogEvent: Sendable {
    case appStarted
    case installStarted
    case installCompleted
    case installCancelled
    case installFailed
    case loginWindowOpened
    case loginPageLoaded
    case loginSucceeded
    case loginUnsupported
    case loginFailed
    case versionCheckStarted
    case versionCheckCompleted(updateRequired: Bool)
    case versionCheckFailed(VersionCheckFailureCategory)
    case launchStarted
    case launchSucceeded
    case launchFailed

    fileprivate var message: String {
        switch self {
        case .appStarted:
            return "앱을 시작했습니다."
        case .installStarted:
            return "설치 또는 업데이트를 시작했습니다."
        case .installCompleted:
            return "설치 또는 업데이트를 완료했습니다."
        case .installCancelled:
            return "설치를 중지했습니다."
        case .installFailed:
            return "설치 또는 업데이트에 실패했습니다."
        case .loginWindowOpened:
            return "공식 로그인 창을 열었습니다."
        case .loginPageLoaded:
            return "공식 로그인 페이지를 불러왔습니다."
        case .loginSucceeded:
            return "로그인에 성공했습니다."
        case .loginUnsupported:
            return "지원하지 않는 로그인 경로입니다."
        case .loginFailed:
            return "로그인에 실패했습니다."
        case .versionCheckStarted:
            return "게임 버전 확인을 시작했습니다."
        case let .versionCheckCompleted(updateRequired):
            return updateRequired ? "게임 업데이트가 필요합니다." : "게임 버전이 최신입니다."
        case let .versionCheckFailed(category):
            return "게임 버전 확인에 실패했습니다. 분류: \(category.rawValue)"
        case .launchStarted:
            return "게임 실행을 시작했습니다."
        case .launchSucceeded:
            return "게임 실행을 요청했습니다."
        case .launchFailed:
            return "게임 실행에 실패했습니다."
        }
    }
}

/// A tiny append-only diagnostic log for safe launcher lifecycle events.
///
/// This class is thread-safe so Core/WebLogin can report events from their
/// async work without crossing the AppKit main-actor boundary.  The event
/// enum is intentionally closed over safe, non-secret messages.
final class LauncherLog: @unchecked Sendable {
    static let shared = LauncherLog()

    private let lock = NSLock()
    private let fileURL: URL
    private let dateFormatter: ISO8601DateFormatter
    private var lines: [String]
    private var observers: [UUID: @Sendable ([String]) -> Void] = [:]

    init(fileURL: URL? = nil) {
        let resolvedFileURL = fileURL ?? LauncherLog.defaultFileURL()
        self.fileURL = resolvedFileURL
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.lines = LauncherLog.loadLines(from: resolvedFileURL)
        ensureLogFile()
    }

    var logFileURL: URL { fileURL }

    /// Appends one safe event and notifies the read-only UI subscribers.
    func record(_ event: LauncherLogEvent) {
        let callbacks: [@Sendable ([String]) -> Void]

        lock.lock()
        let timestamp = dateFormatter.string(from: Date())
        let line = "[" + timestamp + "] " + event.message
        lines.append(line)
        if lines.count > 500 {
            lines.removeFirst(lines.count - 500)
        }
        appendLine(line)
        callbacks = Array(observers.values)
        let currentLines = lines
        lock.unlock()

        for callback in callbacks {
            callback(currentLines)
        }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    /// Registers a UI observer and immediately sends the current snapshot.
    @discardableResult
    func observe(_ observer: @escaping @Sendable ([String]) -> Void) -> UUID {
        let id = UUID()
        let currentLines: [String]

        lock.lock()
        observers[id] = observer
        currentLines = lines
        lock.unlock()

        observer(currentLines)
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    func revealInFinder() {
        ensureLogFile()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func ensureLogFile() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    private func appendLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        ensureLogFile()
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }

    private static func defaultFileURL() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return applicationSupport
            .appendingPathComponent("XIV KR Launcher", isDirectory: true)
            .appendingPathComponent("launcher.log", isDirectory: false)
    }

    private static func loadLines(from fileURL: URL) -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let allLines = text.split(whereSeparator: { $0.isNewline }).map(String.init)
        return Array(allLines.suffix(500))
    }
}
