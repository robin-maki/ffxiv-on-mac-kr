import AppKit
import Foundation
import WebKit

private let officialLoginURL = URL(string: "https://newlauncher.ff14.co.kr/")!
typealias UpdateAction = (@escaping @Sendable (LauncherProgress) -> Void) async throws -> GameVersions
typealias VersionCheckAction = () async throws -> GameVersionStatus

func externalBrowserURL(_ rawURL: URL?) -> URL? {
    guard let rawURL,
          let scheme = rawURL.scheme?.lowercased(),
          let host = rawURL.host?.lowercased(),
          !host.isEmpty,
          rawURL.user == nil,
          rawURL.password == nil else { return nil }
    if scheme == "https", rawURL.port == nil || rawURL.port == 443 { return rawURL }
    guard scheme == "http",
          rawURL.port == nil || rawURL.port == 80,
          host == "ff14.co.kr" || host.hasSuffix(".ff14.co.kr"),
          var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) else {
        return nil
    }
    components.scheme = "https"
    components.port = nil
    return components.url
}

/// AppKit-owned hit target for the official page's custom title bar.
/// WKWebView's internal view hierarchy consumes mouse events before a
/// WKWebView subclass can see them, so the drag target must be a sibling view
/// placed above the page.
private final class LauncherDragOverlay: NSView {
    var trailingControlWidth: CGFloat = 70

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), point.x < bounds.width - trailingControlWidth else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Keep only the newest downloader callback per main-queue turn. This keeps
/// WebKit from retaining a task for every small network chunk.
private final class PatchProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: LauncherProgress?
    private var scheduled = false

    func submit(_ progress: LauncherProgress, deliver: @escaping @MainActor (LauncherProgress) -> Void) {
        lock.lock()
        latest = progress
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        guard shouldSchedule else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let value = self.latest
            self.latest = nil
            self.scheduled = false
            self.lock.unlock()
            if let value { deliver(value) }
        }
    }

    func clear() {
        lock.lock()
        latest = nil
        scheduled = false
        lock.unlock()
    }
}

/// The official page is the launcher's entire UI. The native side only
/// supplies the documented callbacks, performs the update, and starts Wine.
@MainActor
final class WebLoginController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, WKScriptMessageHandler {
    private static let loginContentSize = NSSize(width: 400, height: 690)
    private enum Phase { case idle, checkingVersion, waitingForUpdate, updating, ready, authorizing, launching }

    private let parent: NSWindow
    private let windowsGamePath: String
    private let launcherVersion: String
    private let launch: (String) async throws -> Void
    private let checkVersion: VersionCheckAction
    private let update: UpdateAction
    private let cancelUpdate: () -> Void
    private let message: (String) -> Void
    private var webView: WKWebView?
    private var dragOverlay: LauncherDragOverlay?
    private var closed = false
    private var phase = Phase.idle
    private var updateStarted = false
    private var updateTask: Task<Void, Never>?
    private let patchProgressCoalescer = PatchProgressCoalescer()
    private var lastPatchTextUpdate = Date.distantPast.timeIntervalSinceReferenceDate
    private var patchSpeedFile = ""
    private var patchSpeedBytes: Int64 = 0
    private var patchSpeedTime = Date.timeIntervalSinceReferenceDate
    private var patchBytesPerSecond = 0.0
    private var restoreFrame: NSRect?

    var isClosed: Bool { closed }

    init(
        parent: NSWindow,
        windowsGamePath: String,
        launcherVersion: String,
        launch: @escaping (String) async throws -> Void,
        checkVersion: @escaping VersionCheckAction,
        update: @escaping UpdateAction,
        cancelUpdate: @escaping () -> Void = {},
        message: @escaping (String) -> Void = { _ in }
    ) {
        self.parent = parent
        self.windowsGamePath = windowsGamePath
        self.launcherVersion = launcherVersion
        self.launch = launch
        self.checkVersion = checkVersion
        self.update = update
        self.cancelUpdate = cancelUpdate
        self.message = message
        super.init()
    }

    func show() {
        if let webView {
            resizeForLogin()
            parent.contentView = webView
            parent.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        closed = false
        phase = .idle
        updateStarted = false
        updateTask = nil
        patchProgressCoalescer.clear()
        resetPatchSpeed()
        resizeForLogin()

        // Match the official launcher's cookie behavior. The WebView is still
        // navigation-locked to the exact official origin, while its persistent
        // cookie jar lets the site's own "아이디 저장" option work.
        let dataStore = WKWebsiteDataStore.default()
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(
            source: bridgeScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        userContentController.add(self, name: "xivkr")

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.userContentController = userContentController
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.translatesAutoresizingMaskIntoConstraints = false
        webView = view

        let overlay = LauncherDragOverlay(frame: .zero)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.heightAnchor.constraint(equalToConstant: 40),
        ])
        dragOverlay = overlay

        // This is the app's only window. Do not create a child login window;
        // keeping one WebView also preserves the official page's own state.
        parent.delegate = self
        parent.contentView = view
        parent.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        view.load(URLRequest(url: officialLoginURL, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    /// Tears down the ephemeral page session. The caller owns closing the
    /// window so authentication failures can keep it visible while a
    /// successful game launch follows the official launcher's exit behavior.
    func close() {
        guard !closed else { return }
        closed = true
        updateTask?.cancel()
        cancelUpdate()
        updateTask = nil
        patchProgressCoalescer.clear()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "xivkr")
        dragOverlay?.removeFromSuperview()
        dragOverlay = nil
        parent.delegate = nil
        webView = nil
    }

    private func closeWindow() {
        close()
        parent.close()
    }

    // MARK: WKScriptMessageHandler

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak self] in
            guard let self,
                  message.frameInfo.securityOrigin.protocol.lowercased() == "https",
                  message.frameInfo.securityOrigin.host.lowercased() == "newlauncher.ff14.co.kr",
                  message.frameInfo.securityOrigin.port == 0 || message.frameInfo.securityOrigin.port == 443,
                  let body = message.body as? [String: Any],
                  let name = body["name"] as? String,
                  let args = body["args"] as? [Any] else { return }
            self.handle(name: name, args: args)
        }
    }

    private func handle(name: String, args: [Any]) {
        switch name {
        case "GetDataReady":
            appStartData()
        case "LoginSuccess":
            validateAccountAndPrepareLauncher(args.first as? [String: Any])
        case "ExecutePatch", "ExecuteInstall":
            startOfficialUpdateIfNeeded()
        case "CancelPatch", "CancelInstall":
            cancelOfficialUpdate()
        case "GameStart":
            requestGameToken()
        case "ExecuteClient":
            executeClient(args)
        case "LauncherLogOut":
            LauncherLog.shared.record(.loginFailed)
            cancelOfficialUpdate()
            phase = .idle
            reloadOfficialPage()
        case "Close", "LauncherClose":
            if phase == .idle || phase == .ready { closeWindow() }
        case "LauncherLoginClose":
            if phase == .idle { closeWindow() }
        case "Minimize", "LauncherHidden", "LauncherLoginHidden":
            parent.miniaturize(nil)
        case "LauncherMaximize":
            maximizeLauncher()
        case "LauncherRestoreSize":
            restoreLauncherSize()
        default:
            // Legacy callbacks (SetType, SetUseDirectX11, etc.) are harmless
            // no-ops. They do not expose a native API to the page.
            break
        }
    }

    private func executeClient(_ args: [Any]) {
        let token: String?
        if let value = args.first as? String {
            token = value
        } else if let value = args.first as? [String: Any] {
            token = value["token"] as? String
        } else {
            token = nil
        }
        guard let token, Self.isPlausibleToken(token) else {
            fail("서버가 유효하지 않은 게임 세션을 반환했습니다.")
            return
        }
        guard phase == .authorizing else {
            fail("예상하지 못한 게임 실행 요청을 차단했습니다. 다시 로그인해 주세요.")
            return
        }
        phase = .launching
        showLauncherMessage("게임을 실행하는 중…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // The token is scoped to this call and is never persisted or
                // returned to the page after the launch request.
                try await self.launch(token)
                self.message("게임을 실행했습니다.")
                self.closeWindow()
            } catch {
                self.fail(Self.displayError(error))
            }
        }
    }

    // MARK: Official page flow

    private func appStartData() {
        guard let webView else { return }
        let installPath = windowsGamePath.lowercased().hasSuffix("\\game")
            ? String(windowsGamePath.dropLast(5))
            : windowsGamePath
        let script = """
        (() => {
          if (typeof AppStartData !== 'function') return false;
          AppStartData(1, '1', '0', __XIVKR_GAME_PATH__, __XIVKR_VERSION__);
          return true;
        })();
        """
        .replacingOccurrences(of: "__XIVKR_GAME_PATH__", with: Self.javascriptString(installPath))
        .replacingOccurrences(of: "__XIVKR_VERSION__", with: Self.javascriptString(launcherVersion))
        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                if error != nil || (result as? Bool) != true {
                    self.fail("공식 로그인 페이지를 초기화하지 못했습니다.")
                }
            }
        }
    }

    private func validateAccountAndPrepareLauncher(_ values: [String: Any]?) {
        guard phase == .idle else { return }
        guard let values,
              let csiteNo = values["csiteNo"] as? String,
              let freeIC = values["freeIC"] as? String,
              let freeTrial = values["freeTrial"] as? String else {
            fail("로그인 계정 유형을 확인하지 못했습니다.")
            return
        }
        guard csiteNo == "0", freeIC == "X", freeTrial != "O" else {
            LauncherLog.shared.record(.loginUnsupported)
            fail("액토즈 일반 이용권 계정만 지원합니다. 네이버·카카오·PC방·무료 플레이는 지원하지 않습니다.")
            return
        }
        LauncherLog.shared.record(.loginSucceeded)
        phase = .checkingVersion
        resizeForLauncher()
        checkVersionAndCompleteResize()
    }

    private func checkVersionAndCompleteResize() {
        message("게임 버전을 확인하는 중…")
        LauncherLog.shared.record(.versionCheckStarted)
        Task { @MainActor [weak self] in
            guard let self, !self.closed, self.phase == .checkingVersion else { return }
            do {
                let status = try await self.checkVersion()
                guard !Task.isCancelled, !self.closed, self.phase == .checkingVersion else { return }
                LauncherLog.shared.record(.versionCheckCompleted(updateRequired: status.launcherStatus == "1"))
                self.completeOfficialResize(status: status)
            } catch {
                guard !self.closed, self.phase == .checkingVersion else { return }
                let category: VersionCheckFailureCategory
                switch error as? LauncherError {
                case .manifest: category = .manifest
                case .path: category = .path
                case .network: category = .network
                case .checksum: category = .checksum
                case .cancelled: category = .cancelled
                default: category = .other
                }
                LauncherLog.shared.record(.versionCheckFailed(category))
                self.fail(Self.displayError(error, fallback: "게임 버전을 확인하지 못했습니다."))
            }
        }
    }

    private func completeOfficialResize(status: GameVersionStatus) {
        guard let webView else { return }
        let statusArgument = Self.javascriptString(status.appGameStatusArgument)
        // Set the phase before evaluating JavaScript.  AppGameStatus(1;...) can
        // synchronously cause the page to post ExecutePatch from InitTop.
        phase = status.launcherStatus == "2" ? .ready : .waitingForUpdate
        let script = """
        (() => {
          if (typeof AppCompleteResize !== 'function') return false;
          AppCompleteResize();
          if (typeof AppGameStatus !== 'function') return false;
          AppGameStatus(__XIVKR_STATUS__);
          return true;
        })();
        """
        .replacingOccurrences(of: "__XIVKR_STATUS__", with: statusArgument)
        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                guard error == nil, (result as? Bool) == true else {
                    self.fail("공식 런처 화면을 준비하지 못했습니다.")
                    return
                }
                switch status.launcherStatus {
                case "0": self.message("게임 설치가 필요합니다.")
                case "1": self.message("게임 업데이트가 필요합니다.")
                default: self.message("게임을 시작할 수 있습니다.")
                }
            }
        }
    }

    private func startOfficialUpdateIfNeeded() {
        guard phase == .waitingForUpdate, !updateStarted else { return }
        updateStarted = true
        phase = .updating
        patchProgressCoalescer.clear()
        lastPatchTextUpdate = Date.distantPast.timeIntervalSinceReferenceDate
        resetPatchSpeed()
        updateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let versions = try await self.update { [weak self] progress in
                    self?.patchProgressCoalescer.submit(progress) { [weak self] value in
                        self?.publishPatchProgress(value)
                    }
                }
                guard !Task.isCancelled, !self.closed, self.phase == .updating else { return }
                self.finishOfficialUpdate(versions)
            } catch {
                guard !self.closed, self.phase == .updating else { return }
                self.updateStarted = false
                self.phase = .waitingForUpdate
                if error is CancellationError {
                    self.showLauncherError("업데이트가 취소되었습니다.")
                } else {
                    LauncherLog.shared.record(.installFailed)
                    self.message("게임 업데이트에 실패했습니다.")
                    self.showLauncherError(Self.displayError(error))
                }
            }
            self.updateTask = nil
        }
    }

    private func cancelOfficialUpdate() {
        guard phase == .updating else { return }
        updateStarted = false
        phase = .waitingForUpdate
        cancelUpdate()
        updateTask?.cancel()
        updateTask = nil
        patchProgressCoalescer.clear()
        LauncherLog.shared.record(.installCancelled)
        showLauncherError("업데이트를 취소했습니다.")
    }

    private func finishOfficialUpdate(_ versions: GameVersions) {
        guard let webView else {
            fail("공식 런처 화면을 준비하지 못했습니다.")
            return
        }
        let status = GameVersionStatus(versions: versions, installed: true)
        guard status.launcherStatus == "2" else {
            fail("업데이트 후 게임 버전을 확인하지 못했습니다. 다시 업데이트해 주세요.")
            return
        }
        let versionArgument = Self.javascriptString(status.appGameStatusArgument)
        let script = """
        (() => {
          if (typeof AppGameStart !== 'function') return false;
          AppGameStart(__XIVKR_GAME_START__);
          return true;
        })();
        """
        .replacingOccurrences(of: "__XIVKR_GAME_START__", with: versionArgument)
        webView.evaluateJavaScript(script) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed, self.phase == .updating else { return }
                guard error == nil, (result as? Bool) == true else {
                    self.fail("공식 런처의 게임 시작 화면을 준비하지 못했습니다.")
                    return
                }
                self.updateStarted = false
                self.phase = .ready
                LauncherLog.shared.record(.installCompleted)
                self.message("업데이트가 완료되었습니다. 공식 런처의 게임 시작 버튼을 눌러 주세요.")
            }
        }
    }

    private func requestGameToken() {
        guard phase == .ready else {
            fail("게임을 시작할 수 없는 상태입니다. 업데이트가 끝난 뒤 다시 시도해 주세요.")
            return
        }
        phase = .authorizing
        guard let webView else { return }
        webView.evaluateJavaScript("""
        (() => {
          if (typeof AppGetToken !== 'function') return false;
          AppGetToken(0);
          return true;
        })();
        """) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                if error != nil || (result as? Bool) == false {
                    self.fail("게임 세션을 발급하지 못했습니다.")
                }
            }
        }
    }

    private func publishPatchProgress(_ progress: LauncherProgress) {
        guard phase == .updating, !closed, let webView else { return }
        let now = Date.timeIntervalSinceReferenceDate
        let total = max(progress.totalSize, 1)
        let percent = min(max(Double(progress.downloadedTotal) / Double(total) * 100, 0), 100)
        updatePatchSpeed(progress, now: now)
        let updateText = now - lastPatchTextUpdate >= 1
        if updateText { lastPatchTextUpdate = now }

        let current = Self.formatBytes(progress.downloaded)
        let fileTotal = Self.formatBytes(progress.fileSize)
        let overall = Self.formatBytes(progress.downloadedTotal)
        let overallTotal = Self.formatBytes(progress.totalSize)
        let speed = patchBytesPerSecond > 0
            ? " · \(Self.formatBytes(Int64(patchBytesPerSecond)))/s"
            : ""
        // Keep both values in the official launcher status area.  volume01
        // is the current file/download speed; volume02 is the total bytes and
        // percentage. Do not create a native overlay for normal progress.
        let currentStatus = Self.javascriptString(updateText
            ? "\(progress.fileName) · \(current) / \(fileTotal)\(speed)"
            : "\(current) / \(fileTotal)")
        let percentText = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), percent)
        let totalStatus = Self.javascriptString(updateText
            ? "전체 \(overall) / \(overallTotal) · \(percentText)%"
            : "전체 \(overall) / \(overallTotal)")
        // The official page renders this value as the large percentage.
        // Truncate instead of rounding so it never shows 100% before all
        // bytes have actually arrived.
        let progressValue = String(Int(percent))
        let script = """
        (() => {
          const percent = __XIVKR_PERCENT__;
          const currentStatus = __XIVKR_CURRENT_STATUS__;
          const totalStatus = __XIVKR_TOTAL_STATUS__;
          try { if (typeof AppPatchProgress === 'function') AppPatchProgress(percent); } catch (_) {}
          if (__XIVKR_UPDATE_TEXT__) {
            try { if (typeof AppPatchDownloadStatus === 'function') AppPatchDownloadStatus(currentStatus); } catch (_) {}
            try { if (typeof AppPatchInfo === 'function') AppPatchInfo(totalStatus); } catch (_) {}
          }
          return true;
        })();
        """
        .replacingOccurrences(of: "__XIVKR_PERCENT__", with: progressValue)
        .replacingOccurrences(of: "__XIVKR_CURRENT_STATUS__", with: currentStatus)
        .replacingOccurrences(of: "__XIVKR_TOTAL_STATUS__", with: totalStatus)
        .replacingOccurrences(of: "__XIVKR_UPDATE_TEXT__", with: updateText ? "true" : "false")
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func resetPatchSpeed() {
        patchSpeedFile = ""
        patchSpeedBytes = 0
        patchSpeedTime = Date.timeIntervalSinceReferenceDate
        patchBytesPerSecond = 0
    }

    private func updatePatchSpeed(_ progress: LauncherProgress, now: TimeInterval) {
        if progress.fileName != patchSpeedFile {
            patchSpeedFile = progress.fileName
            patchSpeedBytes = progress.downloaded
            patchSpeedTime = now
            patchBytesPerSecond = 0
            return
        }
        let elapsed = now - patchSpeedTime
        guard elapsed >= 1 else { return }
        let delta = progress.downloaded - patchSpeedBytes
        if delta > 0 { patchBytesPerSecond = Double(delta) / elapsed }
        patchSpeedBytes = progress.downloaded
        patchSpeedTime = now
    }

    private func resizeForLauncher() {
        let visible = (parent.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 24, dy: 24)
            ?? NSRect(x: 0, y: 0, width: 1360, height: 850)
        let width = min(CGFloat(1360), visible.width)
        let height = min(CGFloat(850), visible.height)
        let size = NSSize(width: max(460, width), height: max(760, height))
        dragOverlay?.trailingControlWidth = 180
        restoreFrame = nil
        parent.contentMinSize = NSSize(width: min(size.width, 1360), height: min(size.height, 850))
        parent.setContentSize(size)
        parent.setFrameOrigin(NSPoint(x: visible.midX - parent.frame.width / 2, y: visible.midY - parent.frame.height / 2))
    }

    private func resizeForLogin() {
        let size = Self.loginContentSize
        dragOverlay?.trailingControlWidth = 70
        restoreFrame = nil
        parent.contentMinSize = size
        parent.setContentSize(size)
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            parent.setFrameOrigin(NSPoint(
                x: visible.midX - parent.frame.width / 2,
                y: visible.midY - parent.frame.height / 2
            ))
        }
    }

    private func maximizeLauncher() {
        guard restoreFrame == nil,
              let visible = (parent.screen ?? NSScreen.main)?.visibleFrame else { return }
        restoreFrame = parent.frame
        parent.setFrame(visible, display: true, animate: true)
        updateMaximizeIcon(maximized: true)
    }

    private func restoreLauncherSize() {
        guard let frame = restoreFrame else { return }
        restoreFrame = nil
        parent.setFrame(frame, display: true, animate: true)
        updateMaximizeIcon(maximized: false)
    }

    private func updateMaximizeIcon(maximized: Bool) {
        webView?.evaluateJavaScript("try { if (typeof AppShowMaximizeRestore === 'function') AppShowMaximizeRestore('\(maximized ? "0" : "1")'); } catch (_) {}", completionHandler: nil)
    }

    private func reloadOfficialPage() {
        guard let webView else { return }
        phase = .idle
        updateStarted = false
        patchProgressCoalescer.clear()
        resetPatchSpeed()
        resizeForLogin()
        webView.load(URLRequest(url: officialLoginURL, cachePolicy: .reloadIgnoringLocalCacheData))
    }

    private func fail(_ value: String) {
        phase = .idle
        updateStarted = false
        LauncherLog.shared.record(.loginFailed)
        message(value)
        showLauncherError(value)
        parent.makeKeyAndOrderFront(nil)
    }

    private func showLauncherMessage(_ value: String) {
        guard let webView else { return }
        let text = Self.javascriptString(value)
        webView.evaluateJavaScript(Self.overlayScript(text, color: "#1f6feb"), completionHandler: nil)
    }

    private func showLauncherError(_ value: String) {
        guard let webView else { return }
        let text = Self.javascriptString(value)
        webView.evaluateJavaScript(Self.overlayScript(text, color: "#b42318"), completionHandler: nil)
    }

    private static func overlayScript(_ text: String, color: String) -> String {
        """
        (() => {
          const text = __XIVKR_TEXT__;
          let node = document.getElementById('xivkr-native-message');
          if (!node) {
            node = document.createElement('div');
            node.id = 'xivkr-native-message';
            node.setAttribute('role', 'alert');
            node.style.cssText = 'position:fixed;left:24px;right:24px;bottom:24px;z-index:2147483647;padding:14px 18px;border-radius:8px;color:#fff;font:14px -apple-system,BlinkMacSystemFont,sans-serif;box-shadow:0 3px 18px rgba(0,0,0,.35);';
            (document.body || document.documentElement).appendChild(node);
          }
          node.style.background = '__XIVKR_COLOR__';
          node.textContent = text;
          node.hidden = false;
          return true;
        })();
        """
        .replacingOccurrences(of: "__XIVKR_TEXT__", with: text)
        .replacingOccurrences(of: "__XIVKR_COLOR__", with: color)
    }

    // MARK: Navigation policy

    private func isAllowed(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "newlauncher.ff14.co.kr",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(isAllowed(navigationAction.request.url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(isAllowed(navigationResponse.response.url) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           let url = externalBrowserURL(navigationAction.request.url) {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        fail("공식 로그인 페이지를 불러오지 못했습니다.")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isAllowed(webView.url) else { return }
        LauncherLog.shared.record(.loginPageLoaded)
        webView.evaluateJavaScript("""
        (() => Boolean(
          window.external &&
          typeof window.external.GetDataReady === 'function' &&
          typeof window.external.LoginSuccess === 'function' &&
          typeof window.external.ExecutePatch === 'function' &&
          typeof window.external.ExecuteInstall === 'function' &&
          typeof window.external.GameStart === 'function' &&
          typeof window.external.ExecuteClient === 'function'
        ))();
        """) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }
                if error != nil || (result as? Bool) != true {
                    self.fail("공식 런처 브리지를 초기화하지 못했습니다.")
                }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch phase {
        case .checkingVersion, .updating, .authorizing, .launching:
            return false
        case .idle, .waitingForUpdate, .ready:
            close()
            return true
        }
    }

    // MARK: Script source

    private func bridgeScript() -> String {
        """
        (() => {
          const post = (name, args) => {
            try { window.webkit.messageHandlers.xivkr.postMessage({name: name, args: Array.prototype.slice.call(args)}); } catch (_) {}
          };
          const bridge = {
            GetDataReady() { post('GetDataReady', arguments); return true; },
            LoginSuccess() {
              const value = arguments[0] || window.loginCheck;
              const text = (key) => value && value[key] != null ? String(value[key]) : '';
              post('LoginSuccess', [{csiteNo: text('csiteNo'), freeIC: text('freeIC'), freeTrial: text('freeTrial')}]);
              return true;
            },
            ExecutePatch() { post('ExecutePatch', arguments); return true; },
            ExecuteInstall() { post('ExecuteInstall', arguments); return true; },
            CancelPatch() { post('CancelPatch', arguments); return true; },
            CancelInstall() { post('CancelInstall', arguments); return true; },
            ExecuteClient(token) { post('ExecuteClient', [token]); return true; },
            GameStart() { post('GameStart', arguments); return true; },
            Close() { post('Close', arguments); return true; },
            LauncherClose() { post('LauncherClose', arguments); return true; },
            LauncherLoginClose() { post('LauncherLoginClose', arguments); return true; },
            Minimize() { post('Minimize', arguments); return true; },
            LauncherHidden() { post('LauncherHidden', arguments); return true; },
            LauncherLoginHidden() { post('LauncherLoginHidden', arguments); return true; },
            LauncherMaximize() { post('LauncherMaximize', arguments); return true; },
            LauncherRestoreSize() { post('LauncherRestoreSize', arguments); return true; },
            SetData() { return true; },
            SetType() { return true; },
            SetUseDirectX11() { return true; },
            LauncherLogOut() { post('LauncherLogOut', arguments); return true; }
          };
          let target = null;
          try { target = window.external; } catch (_) {}
          if (!target || (typeof target !== 'object' && typeof target !== 'function')) {
            target = bridge;
            try { Object.defineProperty(window, 'external', {value: target, writable: false, configurable: false}); } catch (_) { try { window.external = target; } catch (_) {} }
          } else {
            Object.keys(bridge).forEach((key) => { try { target[key] = bridge[key]; } catch (_) {} });
          }
          document.addEventListener('DOMContentLoaded', () => {
            document.querySelectorAll('#ch_logo2, #ch_logo3, #ch_logo4, .naverArea, .kakaoArea, .daumArea, .nexonArea').forEach((element) => { element.style.display = 'none'; });
          }, {once: true});
        })();
        """
    }

    private static func javascriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(encoded.dropFirst().dropLast())
    }

    private static func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }

    private static func isPlausibleToken(_ token: String) -> Bool {
        guard token.count >= 40, token.count <= 64 else { return false }
        return token.allSatisfy { $0.isNumber || $0.isLetter || $0 == "+" || $0 == "/" || $0 == "=" }
    }

    private static func displayError(_ error: Error, fallback: String = "게임을 실행하지 못했습니다.") -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? fallback : message
    }
}
