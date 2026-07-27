import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let closeCameraPanel = Notification.Name("closeCameraPanel")
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var promoWindow: NSWindow?
    private var updateSubscription: AnyCancellable?
    private var clickMonitor: Any?
    private var appSwitchObserver: NSObjectProtocol?
    private var savedPanelFrame: NSRect?
    private var savedPanelLevel: NSWindow.Level?
    private(set) var isInTrueFullscreen = false

    let service = ProtectService()
    let updateChecker = UpdateChecker()
    /// Owned here (not by the SwiftUI tree) so closePanel() can disconnect
    /// streams deterministically before the view hierarchy is destroyed.
    let clientManager = RTSPClientManager()
    /// Owns pinned always-on-top camera windows. Their streams are independent
    /// of the popover's, so they keep running while the popover is closed.
    private(set) lazy var pinnedWindows = PinnedWindowManager(service: service)

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
        NotificationCenter.default.addObserver(forName: .layoutProfileChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyProfilePanelSize()
        }
        // Instantiate before the first fetch so the manager's camera-list
        // subscription is in place to restore persisted pins when cameras load.
        _ = pinnedWindows
        let s = AppSettings.shared
        if !s.ipAddress.isEmpty && !s.apiKey.isEmpty {
            Task { await service.fetchCameras() }
        }
        if !s.hasCompletedOnboarding {
            showOnboarding()
        } else {
            promptAutoStartIfNeeded()
            showAppStorePromoIfFirstTime()
        }
        updateChecker.startPeriodicChecks()
        observeUpdatesForAppStorePromo()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Release camera streams (RTSP TEARDOWN + server-side DELETE) so the
        // controller doesn't keep sessions alive against a dead process.
        closePanel()
        // Pinned windows hold their own streams — tear them down too. Their
        // persistence is kept so they reopen on next launch.
        pinnedWindows.closeAll()
        // Those requests are dispatched asynchronously; give them a brief
        // window to reach the controller before the process exits.
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    }

    private func promptAutoStartIfNeeded() {
        let s = AppSettings.shared
        guard !s.hasShownAutoStartPrompt else { return }
        s.hasShownAutoStartPrompt = true

        let alert = NSAlert()
        alert.messageText = String(localized: "Start QuickProtect at Login?")
        alert.informativeText = String(localized: "QuickProtect can start automatically when you log in so your cameras are always one click away.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Enable"))
        alert.addButton(withTitle: String(localized: "Not Now"))

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
        let img = Self.makeApertureTemplate(size: 18)
        img.accessibilityDescription = "QuickProtect"
        button.image = img
        button.action = #selector(handleStatusBarClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self
    }

    /// Draws the Aurora aperture mark (outer ring + quick-shutter top arc + inner lens)
    /// as a template NSImage so the system tints it for light/dark menu bars.
    private static func makeApertureTemplate(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let inset = max(1.0, size * 0.10)
            let bounds = rect.insetBy(dx: inset, dy: inset)
            let line = max(1.0, size * 0.10)

            // Outer ring
            let ring = NSBezierPath(ovalIn: bounds)
            ring.lineWidth = line
            ring.stroke()

            // Inner lens (filled)
            let lensR = bounds.width * 0.22
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            let lens = NSBezierPath(ovalIn: NSRect(
                x: center.x - lensR, y: center.y - lensR,
                width: lensR * 2, height: lensR * 2
            ))
            lens.fill()

            // Top-right quick-shutter arc (thicker stroke)
            let arc = NSBezierPath()
            arc.lineWidth = line * 1.7
            arc.lineCapStyle = .round
            arc.appendArc(
                withCenter: center,
                radius: bounds.width / 2,
                startAngle: 90,   // top
                endAngle: 40,     // sweeps to upper-right
                clockwise: true
            )
            arc.stroke()
            return true
        }
        img.isTemplate = true
        return img
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

        let settingsItem = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit QuickProtect"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
            let content = PopoverContentView(service: service, clientManager: clientManager) { [weak self] in
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

        positionPanelBelowStatusItem()

        service.isPopoverOpen = true
        panel?.makeKeyAndOrderFront(nil)

        // Close on outside click — but not on the status-bar button itself,
        // which toggles through handleStatusBarClick (see below).
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, !self.isPointerOverStatusButton() else { return }
                self.closePanel()
            }
        }

        // Close when the user switches to another app (Cmd-Tab, Dock, …).
        // The panel is non-activating, so there is no deactivation to hook;
        // the click monitor above only sees mouse events.
        if appSwitchObserver == nil {
            appSwitchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.closePanel()
            }
        }

        Task { await service.fetchCameras() }
    }

    /// True while the pointer sits on the status-bar button.
    ///
    /// The panel is a non-activating panel, so the app stays inactive while it
    /// is open and the global click monitor *does* see the status button's own
    /// mouse-down. Closing there would let the matching mouse-up re-open the
    /// panel via handleStatusBarClick — the icon would never appear to toggle.
    /// Clicks on the button are left to that action instead.
    private func isPointerOverStatusButton() -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        return buttonRect.contains(NSEvent.mouseLocation)
    }

    /// Anchor the panel under the status-bar button, clamped to the screen.
    private func positionPanelBelowStatusItem() {
        guard let panel, let button = statusItem?.button else { return }
        let buttonRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) ?? .zero
        let size = panel.frame.size
        var x = buttonRect.midX - size.width / 2
        let y = buttonRect.minY - size.height - 4
        if let screen = NSScreen.main {
            let sf = screen.visibleFrame
            x = max(sf.minX + 4, min(x, sf.maxX - size.width - 4))
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// On a profile switch, restore that profile's saved window size for the
    /// current display. A profile with no saved size adopts the current size.
    private func applyProfilePanelSize() {
        guard let panel, panel.isVisible, !isInTrueFullscreen else { return }
        if let size = AppSettings.shared.panelSize() {
            guard size != panel.frame.size else { return }
            panel.setContentSize(size)
            positionPanelBelowStatusItem()
        } else {
            AppSettings.shared.setPanelSize(panel.frame.size)
        }
    }

    private func closePanel() {
        service.isPopoverOpen = false
        // Tear streams down explicitly: the hosting controller is destroyed
        // below in the same runloop turn, so a SwiftUI .onChange observing
        // isPopoverOpen would never get an update pass to run in.
        clientManager.disconnectAll()
        service.cleanupStreams()
        panel?.orderOut(nil)
        // Destroy the hosting controller so the panel is rebuilt fresh in
        // showPanel().
        panel?.contentViewController = nil
        panel = nil
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let observer = appSwitchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appSwitchObserver = nil
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
        guard let win = notification.object as? NSPanel, win === panel, !isInTrueFullscreen else { return }
        AppSettings.shared.setPanelSize(win.frame.size)
    }

    func windowWillClose(_ notification: Notification) {
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
        Self.animatePanelFrame(panel, to: screen.frame)
    }

    /// Resize the panel with a soft ease-out that approximates the SwiftUI
    /// `.spring` used for grid↔focus, so the focus→fullscreen step feels like a
    /// continuation of the same motion rather than a different animation engine.
    private static func animatePanelFrame(_ panel: NSPanel, to frame: NSRect) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.42
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func exitPanelFullscreen() {
        guard let panel = panel, isInTrueFullscreen else { return }
        isInTrueFullscreen = false

        // Restore original panel style
        panel.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView]
        panel.level = savedPanelLevel ?? .floating
        panel.hasShadow = true
        if let frame = savedPanelFrame {
            Self.animatePanelFrame(panel, to: frame)
        }
        savedPanelFrame = nil
    }

    // MARK: - Onboarding window

    private func showOnboarding() {
        guard onboardingWindow == nil else { return }
        let view = OnboardingView(service: service) { [weak self] in
            AppSettings.shared.hasCompletedOnboarding = true
            AppSettings.shared.hasShownAutoStartPrompt = true  // replace legacy alert
            self?.onboardingWindow?.close()
        }
        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        win.title = "QuickProtect"
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.setContentSize(NSSize(width: 720, height: 540))
        win.isReleasedWhenClosed = false
        win.center()
        onboardingWindow = win
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            self?.onboardingWindow = nil
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - App Store promo (non-App-Store builds only)

    /// One-time, on the first launch after this version ships: nudge GitHub-build
    /// users toward the App Store edition. Never shown in App Store builds.
    private func showAppStorePromoIfFirstTime() {
        guard !AppDistribution.isAppStore,
              !AppSettings.shared.hasShownAppStorePromo else { return }
        AppSettings.shared.hasShownAppStorePromo = true
        showAppStorePromo(updateVersion: nil)
    }

    /// When a newer GitHub release is found, surface the App Store option once per
    /// new version (alongside the manual download). App Store builds never check.
    private func observeUpdatesForAppStorePromo() {
        guard !AppDistribution.isAppStore else { return }
        updateSubscription = updateChecker.$updateAvailable
            .receive(on: RunLoop.main)
            .sink { [weak self] available in
                guard let self, available else { return }
                let version = self.updateChecker.latestVersion
                guard !version.isEmpty,
                      version != AppSettings.shared.lastPromotedUpdateVersion else { return }
                AppSettings.shared.lastPromotedUpdateVersion = version
                self.showAppStorePromo(updateVersion: version)
            }
    }

    private func showAppStorePromo(updateVersion: String?) {
        guard promoWindow == nil else { return }
        let onGitHub: (() -> Void)? = updateVersion == nil ? nil : { [weak self] in
            self?.updateChecker.openReleasePage()
            self?.promoWindow?.close()
        }
        let view = AppStorePromoView(
            updateVersion: updateVersion,
            onAppStore: { [weak self] in
                AppStorePromo.open()
                self?.promoWindow?.close()
            },
            onGitHub: onGitHub,
            onDismiss: { [weak self] in self?.promoWindow?.close() }
        )
        let win = NSWindow(contentViewController: NSHostingController(rootView: view))
        win.title = "QuickProtect"
        win.styleMask = [.titled, .closable, .fullSizeContentView]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isReleasedWhenClosed = false
        win.center()
        promoWindow = win
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            self?.promoWindow = nil
            NSApp.setActivationPolicy(.accessory)
        }
        NSApp.setActivationPolicy(.regular)
        // Activating mid-launch is racy for an agent app and can leave the window
        // behind the frontmost app — defer a tick and force it forward.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
        }
    }

    // MARK: - Settings window

    func openSettings() {
        closePanel()
        if settingsWindow == nil {
            let view = SettingsView(service: service, updateChecker: updateChecker)
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.title = String(localized: "QuickProtect – Settings")
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 820, height: 600))
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
