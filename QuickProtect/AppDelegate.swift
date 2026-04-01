import AppKit
import SwiftUI

extension Notification.Name {
    static let closeCameraPanel = Notification.Name("closeCameraPanel")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var clickMonitor: Any?
    private var savedPanelFrame: NSRect?
    private var savedPanelLevel: NSWindow.Level?
    private(set) var isInTrueFullscreen = false

    let service = ProtectService()
    let updateChecker = UpdateChecker()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupGlobalHotkey()
        NotificationCenter.default.addObserver(forName: .closeCameraPanel, object: nil, queue: .main) { [weak self] _ in
            self?.closePanel()
        }
        NotificationCenter.default.addObserver(forName: .enterTrueFullscreen, object: nil, queue: .main) { [weak self] _ in
            self?.enterPanelFullscreen()
        }
        NotificationCenter.default.addObserver(forName: .exitTrueFullscreen, object: nil, queue: .main) { [weak self] _ in
            self?.exitPanelFullscreen()
        }
        let s = AppSettings.shared
        if !s.ipAddress.isEmpty && !s.apiKey.isEmpty {
            Task { await service.fetchCameras() }
        }
        promptAutoStartIfNeeded()
        updateChecker.startPeriodicChecks()
    }

    private func promptAutoStartIfNeeded() {
        let s = AppSettings.shared
        guard !s.hasShownAutoStartPrompt else { return }
        s.hasShownAutoStartPrompt = true

        let alert = NSAlert()
        alert.messageText = "Start QuickProtect at Login?"
        alert.informativeText = "QuickProtect can start automatically when you log in so your cameras are always one click away."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not Now")

        // Show as a floating alert (app is .accessory so there's no dock icon)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        NSApp.setActivationPolicy(.accessory)

        if response == .alertFirstButtonReturn {
            s.launchAtLogin = true
        }
    }

    func setupGlobalHotkey() {
        HotkeyManager.shared.onHotkey = { [weak self] in
            self?.togglePanel()
        }
        HotkeyManager.shared.registerFromSettings()
    }

    // MARK: - Status bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "QuickProtect")
        button.action = #selector(handleStatusBarClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
    }

    // MARK: - Click handling

    @objc private func handleStatusBarClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    @objc private func togglePanel() {
        if let p = panel, p.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showContextMenu() {
        closePanel()

        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit QuickProtect", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openSettingsFromMenu() {
        openSettings()
    }

    // MARK: - Camera panel (resizable, anchored to status bar)

    private func showPanel() {
        guard let button = statusItem?.button else { return }

        if panel == nil {
            let size = savedPanelSize()
            let content = PopoverContentView(service: service) { [weak self] in
                self?.openSettings()
            }
            let hostingController = NSHostingController(rootView: content)

            let p = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            p.titlebarAppearsTransparent = true
            p.titleVisibility = .hidden
            p.isMovableByWindowBackground = false
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.isOpaque = false
            p.backgroundColor = NSColor(white: 0.07, alpha: 0.98)
            p.contentViewController = hostingController
            p.delegate = self
            p.minSize = NSSize(width: 400, height: 300)
            panel = p
        }

        // Restore saved size (may differ from creation size if panel was reused)
        let size = savedPanelSize()
        panel?.setContentSize(size)

        // Position below the status bar button, clamped to screen
        let buttonRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        let panelSize = panel!.frame.size
        var x = buttonRect.midX - panelSize.width / 2
        let y = buttonRect.minY - panelSize.height - 4
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            x = max(sf.minX + 4, min(x, sf.maxX - panelSize.width - 4))
        }
        panel?.setFrameOrigin(NSPoint(x: x, y: y))

        service.isPopoverOpen = true
        panel?.makeKeyAndOrderFront(nil)

        // Close on outside click
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.closePanel()
            }
        }

        Task { await service.fetchCameras() }
    }

    private func closePanel() {
        service.isPopoverOpen = false
        panel?.orderOut(nil)
        // Destroy the hosting controller so SwiftUI tears down CameraCells
        // and their RTSPClients disconnect. Recreated in showPanel().
        panel?.contentViewController = nil
        panel = nil
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func savedPanelSize() -> NSSize {
        if let saved = AppSettings.shared.panelSize() { return saved }
        // Default: ~25% of screen area with 16:10 aspect ratio
        guard let screen = NSScreen.main else { return NSSize(width: 640, height: 400) }
        let screenArea = screen.visibleFrame.width * screen.visibleFrame.height
        let panelArea = screenArea * 0.25
        let w = sqrt(panelArea * 16.0 / 10.0).rounded()
        let h = (w * 10.0 / 16.0).rounded()
        return NSSize(width: min(w, 1400), height: min(h, 900))
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        guard let win = notification.object as? NSPanel, win === panel else { return }
        AppSettings.shared.setPanelSize(win.frame.size)
    }

    func windowDidClose(_ notification: Notification) {
        if let win = notification.object as? NSPanel, win === panel {
            closePanel()
        }
    }

    // MARK: - True fullscreen (panel resize — no layer re-parenting needed)

    private func enterPanelFullscreen() {
        guard let panel = panel, let screen = panel.screen ?? NSScreen.main else { return }
        guard !isInTrueFullscreen else { return }

        savedPanelFrame = panel.frame
        savedPanelLevel = panel.level
        isInTrueFullscreen = true

        // Remove title bar and go borderless fullscreen
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.level = .screenSaver
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.setFrame(screen.frame, display: true, animate: true)
    }

    private func exitPanelFullscreen() {
        guard let panel = panel, isInTrueFullscreen else { return }
        isInTrueFullscreen = false

        // Restore original panel style
        panel.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView]
        panel.level = savedPanelLevel ?? .floating
        panel.hasShadow = true
        if let frame = savedPanelFrame {
            panel.setFrame(frame, display: true, animate: true)
        }
        savedPanelFrame = nil
    }

    // MARK: - Settings window

    func openSettings() {
        closePanel()
        if settingsWindow == nil {
            let view = SettingsView(service: service, updateChecker: updateChecker)
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.title = "QuickProtect – Settings"
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 660, height: 520))
            win.isReleasedWhenClosed = false
            settingsWindow = win
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                self?.settingsWindow = nil
                NSApp.setActivationPolicy(.accessory)
            }
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
