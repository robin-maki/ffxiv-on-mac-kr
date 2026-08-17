import AppKit
import Foundation

/// The small interface the native shell expects from Core.swift.
struct LauncherProgress: Sendable {
    let index: Int
    let total: Int
    let fileName: String
    let downloaded: Int64
    let fileSize: Int64
    let downloadedTotal: Int64
    let totalSize: Int64
}

private final class LauncherWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

protocol LauncherCoreAPI: AnyObject {
    var windowsGamePath: String { get }
    func checkVersion() async throws -> GameVersionStatus
    func install(progress: @escaping @Sendable (LauncherProgress) -> Void) async throws -> GameVersions
    func cancelInstall()
    func launch(token: String) async throws
}

/// A tiny progress view shown in the Dock tile while the official page is
/// downloading files. The web page is the only content of the main window.
private final class DockProgressView: NSView {
    private let icon: NSImage
    private var fraction = 0.0

    init(frame: NSRect, icon: NSImage) {
        self.icon = icon
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(fraction: Double) {
        self.fraction = min(max(fraction, 0), 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)
        let track = NSRect(
            x: bounds.minX + 12,
            y: bounds.minY + 10,
            width: max(0, bounds.width - 24),
            height: 10
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: track.insetBy(dx: -2, dy: -2), xRadius: 7, yRadius: 7).fill()
        NSColor.white.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 5, yRadius: 5).fill()
        let filled = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
        guard filled.width > 0 else { return }
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 5, yRadius: 5).fill()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let core: any LauncherCoreAPI
    private let logger = LauncherLog.shared
    private var window: NSWindow!
    private var login: WebLoginController?
    private var dockProgressView: DockProgressView?

    init(core: any LauncherCoreAPI = LauncherCore()) {
        self.core = core
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        logger.record(.appStarted)
        logger.record(.loginWindowOpened)

        let controller = WebLoginController(
            parent: window,
            windowsGamePath: core.windowsGamePath,
            launcherVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            launch: { [weak self] token in
                guard let self else { return }
                self.logger.record(.launchStarted)
                do {
                    try await self.core.launch(token: token)
                    self.logger.record(.loginSucceeded)
                    self.logger.record(.launchSucceeded)
                } catch {
                    self.logger.record(.launchFailed)
                    throw error
                }
            },
            checkVersion: { [weak self] in
                guard let self else { throw LauncherError.cancelled }
                return try await self.core.checkVersion()
            },
            update: { [weak self] progress in
                guard let self else { throw LauncherError.cancelled }
                return try await self.updateAfterLogin(progress: progress)
            },
            cancelUpdate: { [weak self] in
                self?.core.cancelInstall()
            },
            message: { _ in }
        )
        login = controller
        controller.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        login?.close()
        clearDockProgress()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "XIV KR Launcher")
        let logItem = NSMenuItem(title: "로그 파일 보기", action: #selector(openLogPressed), keyEquivalent: "l")
        logItem.target = self
        appMenu.addItem(logItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        window = LauncherWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 690),
            styleMask: [.borderless, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "XIV KR Launcher"
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 400, height: 690)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateAfterLogin(
        progress: @escaping @Sendable (LauncherProgress) -> Void
    ) async throws -> GameVersions {
        logger.record(.installStarted)
        updateDockProgress(0)
        do {
            let versions = try await core.install { [weak self] value in
                progress(value)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let fraction = value.totalSize > 0
                        ? Double(value.downloadedTotal) / Double(value.totalSize)
                        : 0
                    self.updateDockProgress(fraction)
                }
            }
            logger.record(.installCompleted)
            clearDockProgress()
            return versions
        } catch {
            logger.record(.installFailed)
            clearDockProgress()
            throw error
        }
    }

    private func updateDockProgress(_ fraction: Double) {
        if dockProgressView == nil {
            dockProgressView = DockProgressView(
                frame: NSRect(origin: .zero, size: NSApp.dockTile.size),
                icon: NSApp.applicationIconImage
            )
            NSApp.dockTile.contentView = dockProgressView
        }
        dockProgressView?.update(fraction: fraction)
        NSApp.dockTile.display()
    }

    private func clearDockProgress() {
        guard dockProgressView != nil else { return }
        dockProgressView = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }

    @objc private func openLogPressed() {
        logger.revealInFinder()
    }
}

@main
enum XIVKRLauncherMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
