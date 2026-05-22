import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let codexBundleIdentifier = "com.openai.codex"
    private let snapshotService = QuotaSnapshotService()
    private let stateStore = WidgetStateStore()
    private let touchBarController = TouchBarController()
    private let refreshQueue = DispatchQueue(label: "com.wendy.codex-quota-widget.refresh")

    private lazy var windowController = WidgetWindowController(stateStore: stateStore)

    private var appObservers: [NSObjectProtocol] = []
    private var refreshTimer: Timer?
    private var codexRunning = false
    private var fastRefreshUntil: Date?
    private var lastSnapshot: QuotaSnapshot?
    private var refreshInFlight = false
    private var language: WidgetLanguage = .english

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        language = stateStore.load().language ?? .english
        touchBarController.setLanguage(language)
        windowController.onRequestRefresh = { [weak self] in
            self?.refreshState(reason: "manual-refresh", forceSnapshotReload: true)
        }
        windowController.onShowTouchBar = { [weak self] in
            self?.touchBarController.showAgain()
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
        snapshotService.stop()
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

        appObservers = [launchObserver, terminateObserver]
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

        if running != codexRunning {
            codexRunning = running
            if running {
                fastRefreshUntil = Date().addingTimeInterval(120)
            }
        }

        if !running {
            windowController.hide()
            touchBarController.codexDidExit()
            snapshotService.stop()
            lastSnapshot = nil
            scheduleRefreshTimer(cadence: .hidden)
            return
        }

        if reason == "codex-launch" {
            touchBarController.codexDidLaunch()
        }

        windowController.show(snapshot: lastSnapshot)
        touchBarController.show(snapshot: lastSnapshot)
        refreshSnapshot(forceReload: forceSnapshotReload)
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

    private func toggleLanguage() -> WidgetLanguage {
        language = language.toggled
        stateStore.update { state in
            state.language = language
        }
        touchBarController.setLanguage(language)
        touchBarController.showAgain()
        return language
    }

    private func refreshSnapshot(forceReload: Bool) {
        if refreshInFlight {
            return
        }

        refreshInFlight = true
        refreshQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.snapshotService.latestSnapshot(forceReload: forceReload)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refreshInFlight = false
                guard self.codexRunning else {
                    return
                }

                self.lastSnapshot = snapshot
                self.windowController.show(snapshot: snapshot)
                self.touchBarController.show(snapshot: snapshot)
            }
        }
    }
}
