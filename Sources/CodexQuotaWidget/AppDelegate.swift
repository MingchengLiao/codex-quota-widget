import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let codexBundleIdentifier = "com.openai.codex"
    private let codexSnapshotService = QuotaSnapshotService()
    private let claudeSnapshotService = ClaudeCodeSnapshotService()
    private let stateStore = WidgetStateStore()
    private let touchBarController = TouchBarController()
    private let refreshQueue = DispatchQueue(label: "com.wendy.codex-quota-widget.refresh")

    private lazy var windowController = WidgetWindowController(stateStore: stateStore)

    private var appObservers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var codexRunning = false
    private var fastRefreshUntil: Date?
    private var lastCodexSnapshot: QuotaSnapshot?
    private var lastClaudeSnapshot: QuotaSnapshot?
    private var refreshInFlight = false
    private var widgetEnabled = true
    private var language: WidgetLanguage = .english
    private var capsuleEnabled = true
    private var capsuleHiddenUntilCodexRelaunch = false
    private var touchBarProviderMode: TouchBarProviderMode = .both
    private var touchBarPinned = false
    private var touchBarYieldedToForegroundApp = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let state = stateStore.load()
        widgetEnabled = state.widgetEnabled ?? true
        language = state.language ?? .english
        capsuleEnabled = state.capsuleEnabled ?? true
        touchBarProviderMode = state.touchBarProviderMode ?? .both
        touchBarPinned = state.touchBarPinned ?? false
        touchBarYieldedToForegroundApp = !touchBarPinned && !isCodexFrontmost()
        touchBarController.setLanguage(language)
        windowController.onRequestRefresh = { [weak self] in
            self?.refreshState(reason: "manual-refresh", forceSnapshotReload: true)
        }
        windowController.onShowTouchBar = { [weak self] in
            self?.touchBarController.showAgain()
        }
        windowController.onHideCapsule = { [weak self] in
            self?.hideCapsule()
        }
        windowController.onDisableWidget = { [weak self] in
            self?.setWidgetEnabled(false)
        }
        windowController.onOpenTouchBarSettings = { [weak self] in
            self?.openTouchBarSettings()
        }
        windowController.currentLanguage = { [weak self] in
            self?.language ?? .english
        }
        windowController.onToggleLanguage = { [weak self] in
            self?.toggleLanguage() ?? .english
        }
        startMonitoringCodex()
        refreshState(reason: "launch")
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        touchBarController.codexDidExit()
        codexSnapshotService.stop()
        let center = NSWorkspace.shared.notificationCenter
        appObservers.forEach(center.removeObserver(_:))
    }

    private func startMonitoringCodex() {
        let center = NSWorkspace.shared.notificationCenter

        let launchObserver = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWorkspaceEvent(notification, launched: true)
        }

        let terminateObserver = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleWorkspaceEvent(notification, launched: false)
        }

        // When pinned, reclaim the Touch Bar whenever another app comes forward
        // (macOS otherwise yields the system-modal Touch Bar to that app).
        let activateObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.touchBarPinned {
                self.touchBarController.reassertPresentation()
                return
            }

            if self.isCodexFrontmost() {
                self.touchBarYieldedToForegroundApp = false
                self.showTouchBar()
            } else {
                self.touchBarYieldedToForegroundApp = true
                self.touchBarController.hideForInactiveApp()
            }
        }

        appObservers = [launchObserver, terminateObserver, activateObserver]
    }

    private func handleWorkspaceEvent(_ notification: Notification, launched: Bool) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.bundleIdentifier == codexBundleIdentifier
        else {
            return
        }

        if launched {
            fastRefreshUntil = Date().addingTimeInterval(120)
            capsuleHiddenUntilCodexRelaunch = false
            touchBarYieldedToForegroundApp = false
        }
        refreshState(reason: launched ? "codex-launch" : "codex-exit")
    }

    private func scheduleRefreshTimer(cadence: RefreshCadence) {
        if refreshTimer?.timeInterval == cadence.interval {
            return
        }

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: cadence.interval, repeats: true) { [weak self] _ in
            self?.refreshState(reason: "refresh")
        }
        if let refreshTimer {
            RunLoop.main.add(refreshTimer, forMode: .common)
        }
    }

    private func refreshState(reason: String, forceSnapshotReload: Bool = false) {
        let running = isCodexRunning()
        lastClaudeSnapshot = claudeSnapshotService.latestSnapshot()

        if running != codexRunning {
            codexRunning = running
            if running {
                fastRefreshUntil = Date().addingTimeInterval(120)
            }
        }

        if !running {
            capsuleHiddenUntilCodexRelaunch = false
        }

        guard widgetEnabled else {
            hideWidgetSurfaces()
            refreshTimer?.invalidate()
            refreshTimer = nil
            return
        }

        if reason == "codex-launch" {
            touchBarController.codexDidLaunch()
        }

        if running, shouldShowCapsule {
            windowController.show(snapshot: lastCodexSnapshot)
        } else {
            windowController.hide()
        }

        showTouchBar()

        if touchBarProviderMode.showsCodex {
            refreshCodexSnapshot(forceReload: forceSnapshotReload)
        }

        scheduleRefreshTimer(cadence: currentCadence())

        if reason == "refresh", let fastRefreshUntil, fastRefreshUntil < Date() {
            scheduleRefreshTimer(cadence: .normal)
        }
    }

    private func currentCadence() -> RefreshCadence {
        if let fastRefreshUntil, fastRefreshUntil > Date() {
            return .fast
        }
        return .normal
    }

    private func isCodexRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier).isEmpty
    }

    private func isCodexFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == codexBundleIdentifier
    }

    private func showTouchBar() {
        touchBarController.show(
            claudeSnapshot: touchBarProviderMode.showsClaude ? lastClaudeSnapshot : nil,
            codexSnapshot: touchBarProviderMode.showsCodex ? lastCodexSnapshot : nil,
            mode: touchBarProviderMode,
            shouldPresent: touchBarPinned || !touchBarYieldedToForegroundApp
        )
    }

    private var shouldShowCapsule: Bool {
        capsuleEnabled && !capsuleHiddenUntilCodexRelaunch
    }

    private func hideCapsule() {
        capsuleHiddenUntilCodexRelaunch = true
        windowController.hide()
    }

    private func setWidgetEnabled(_ enabled: Bool) {
        widgetEnabled = enabled
        stateStore.update { state in
            state.widgetEnabled = enabled
        }
        refreshState(reason: enabled ? "widget-enabled" : "widget-disabled")
    }

    private func hideWidgetSurfaces() {
        windowController.hide()
        touchBarController.hideForInactiveApp()
    }

    private func toggleLanguage() -> WidgetLanguage {
        language = language.toggled
        stateStore.update { state in
            state.language = language
        }
        touchBarController.setLanguage(language)
        touchBarController.showAgain()
        return language
    }

    private func openTouchBarSettings() {
        let settingsURLs = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard",
        ]

        for rawURL in settingsURLs {
            guard let url = URL(string: rawURL) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private func refreshCodexSnapshot(forceReload: Bool) {
        if refreshInFlight {
            return
        }

        refreshInFlight = true
        refreshQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.codexSnapshotService.latestSnapshot(forceReload: forceReload)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshInFlight = false
                self.lastCodexSnapshot = snapshot
                guard self.widgetEnabled else {
                    self.hideWidgetSurfaces()
                    return
                }
                if self.shouldShowCapsule {
                    self.windowController.show(snapshot: snapshot)
                } else {
                    self.windowController.hide()
                }
                self.showTouchBar()
            }
        }
    }
}
