import AppKit
import Darwin

final class TouchBarController: NSObject, NSTouchBarDelegate {
    private static let itemIdentifier = NSTouchBarItem.Identifier("com.wendy.codex-quota-widget.quota")
    private static let trayIdentifier = "com.wendy.codex-quota-widget"
    private static let systemModalPlacement: Int64 = 1

    private let touchBar = NSTouchBar()
    private let quotaView = TouchBarQuotaView()

    private var systemTrayItem: NSCustomTouchBarItem?
    private var isUserHidden = false
    private(set) var isPresented = false
    private var lastClaudeSnapshot: QuotaSnapshot?
    private var lastCodexSnapshot: QuotaSnapshot?
    private var providerMode: TouchBarProviderMode = .both
    private var language: WidgetLanguage = .english

    override init() {
        super.init()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [Self.itemIdentifier]
    }

    func codexDidLaunch() {
        isUserHidden = false
    }

    func codexDidExit() {
        dismiss()
        isUserHidden = false
        lastClaudeSnapshot = nil
        lastCodexSnapshot = nil
    }

    // Whether any provider segment currently has something worth showing. The
    // Claude segment only counts when it has a fresh snapshot; the Codex segment
    // counts whenever the Codex side is enabled (it renders its own placeholder).
    private var hasVisibleContent: Bool {
        (providerMode.showsClaude && lastClaudeSnapshot != nil) || providerMode.showsCodex
    }

    func show(claudeSnapshot: QuotaSnapshot?, codexSnapshot: QuotaSnapshot?, mode: TouchBarProviderMode) {
        lastClaudeSnapshot = claudeSnapshot
        lastCodexSnapshot = codexSnapshot
        providerMode = mode
        quotaView.render(claudeSnapshot: claudeSnapshot, codexSnapshot: codexSnapshot, mode: mode, language: language)

        guard !isUserHidden else {
            return
        }

        // Nothing to show (e.g. Claude-only mode while Claude Code is idle):
        // yield the Touch Bar to the foreground app instead of holding an empty bar.
        guard hasVisibleContent else {
            dismiss()
            return
        }

        if isPresented {
            hideCloseBox()
        }
        present()
    }

    func showAgain() {
        isUserHidden = false
        quotaView.render(
            claudeSnapshot: lastClaudeSnapshot,
            codexSnapshot: lastCodexSnapshot,
            mode: providerMode,
            language: language
        )
        isPresented = false
        present()
    }

    func setLanguage(_ language: WidgetLanguage) {
        self.language = language
        quotaView.render(
            claudeSnapshot: lastClaudeSnapshot,
            codexSnapshot: lastCodexSnapshot,
            mode: providerMode,
            language: language
        )
    }

    /// Re-present the quota view onto the Touch Bar after another app pulled it
    /// away. Used by pinned mode on app-activation. Respects an explicit
    /// user-initiated hide.
    func reassertPresentation() {
        guard !isUserHidden, hasVisibleContent else {
            return
        }
        isPresented = false
        present()
    }

    func hideForCurrentCodexRun() {
        isUserHidden = true
        dismiss()
    }

    func hideForInactiveApp() {
        dismiss()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == Self.itemIdentifier else {
            return nil
        }

        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = quotaView
        return item
    }

    private func present() {
        guard !isPresented else {
            return
        }
        registerSystemTrayItem()
        SystemModalTouchBarCloseBox.setVisible(false)

        guard presentSystemModalTouchBar() else {
            return
        }
        isPresented = true
        hideCloseBox()
    }

    private func dismiss() {
        guard isPresented else {
            return
        }

        let selectors = [
            "dismissSystemModalTouchBar:",
            "dismissSystemModalFunctionBar:",
        ]

        _ = performTouchBarClassSelector(selectors, first: touchBar, second: nil)
        isPresented = false
        SystemModalTouchBarCloseBox.setVisible(true)
        unregisterSystemTrayItem()
    }

    private func hideCloseBox() {
        SystemModalTouchBarCloseBox.setVisible(false)
        DispatchQueue.main.async {
            SystemModalTouchBarCloseBox.setVisible(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            SystemModalTouchBarCloseBox.setVisible(false)
        }
    }

    private func registerSystemTrayItem() {
        guard systemTrayItem == nil else {
            return
        }

        let item = NSCustomTouchBarItem(identifier: NSTouchBarItem.Identifier(Self.trayIdentifier))
        let button = NSButton(title: "Codex", target: self, action: #selector(handleSystemTrayItemTap))
        button.bezelColor = WidgetColors.color(for: 100)
        item.view = button
        systemTrayItem = item

        SystemTrayTouchBarItem.add(item)
        SystemTrayTouchBarItem.setPresence(identifier: Self.trayIdentifier, visible: true)
    }

    private func unregisterSystemTrayItem() {
        guard let systemTrayItem else {
            return
        }

        SystemTrayTouchBarItem.setPresence(identifier: Self.trayIdentifier, visible: false)
        SystemTrayTouchBarItem.remove(systemTrayItem)
        self.systemTrayItem = nil
    }

    @objc
    private func handleSystemTrayItemTap() {
        showAgain()
    }

    private func presentSystemModalTouchBar() -> Bool {
        let placementSelectors = [
            "presentSystemModalTouchBar:placement:systemTrayItemIdentifier:",
            "presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:",
        ]
        if performTouchBarPlacementSelector(
            placementSelectors,
            touchBar: touchBar,
            placement: Self.systemModalPlacement,
            identifier: Self.trayIdentifier as NSString
        ) {
            return true
        }

        let selectors = [
            "presentSystemModalTouchBar:systemTrayItemIdentifier:",
            "presentSystemModalFunctionBar:systemTrayItemIdentifier:",
        ]
        return performTouchBarClassSelector(selectors, first: touchBar, second: Self.trayIdentifier as NSString)
    }

    private func performTouchBarPlacementSelector(
        _ selectorNames: [String],
        touchBar: NSTouchBar,
        placement: Int64,
        identifier: NSString
    ) -> Bool {
        for selectorName in selectorNames {
            let selector = NSSelectorFromString(selectorName)
            let target = NSTouchBar.self as AnyObject
            guard target.responds(to: selector), let messageSend = SystemModalObjCMessageSend.touchBarPlacement else {
                continue
            }

            messageSend(target, selector, touchBar, placement, identifier)
            return true
        }
        return false
    }

    private func performTouchBarClassSelector(_ selectorNames: [String], first: Any, second: Any?) -> Bool {
        for selectorName in selectorNames {
            let selector = NSSelectorFromString(selectorName)
            let target = NSTouchBar.self as AnyObject
            guard target.responds(to: selector) else {
                continue
            }

            if let second {
                _ = target.perform(selector, with: first, with: second)
            } else {
                _ = target.perform(selector, with: first)
            }
            return true
        }
        return false
    }
}

private enum SystemModalObjCMessageSend {
    typealias TouchBarPlacement = @convention(c) (AnyObject, Selector, NSTouchBar, Int64, NSString) -> Void

    static let touchBarPlacement: TouchBarPlacement? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else {
            return nil
        }
        return unsafeBitCast(symbol, to: TouchBarPlacement.self)
    }()
}

private enum SystemModalTouchBarCloseBox {
    private typealias SetVisibleFunction = @convention(c) (ObjCBool) -> Void

    private static var function: SetVisibleFunction?
    private static var didLoadFunction = false

    static func setVisible(_ visible: Bool) {
        guard let function = loadFunctionIfNeeded() else {
            return
        }
        function(ObjCBool(visible))
    }

    private static func loadFunctionIfNeeded() -> SetVisibleFunction? {
        if didLoadFunction {
            return function
        }
        didLoadFunction = true

        let frameworkPath = "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            return nil
        }
        guard let symbol = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else {
            return nil
        }
        function = unsafeBitCast(symbol, to: SetVisibleFunction.self)
        return function
    }
}

private enum SystemTrayTouchBarItem {
    private typealias SetPresenceFunction = @convention(c) (NSString, ObjCBool) -> Void

    private static var setPresenceFunction: SetPresenceFunction?
    private static var didLoadSetPresenceFunction = false

    static func add(_ item: NSTouchBarItem) {
        performItemClassSelector("addSystemTrayItem:", item: item)
    }

    static func remove(_ item: NSTouchBarItem) {
        performItemClassSelector("removeSystemTrayItem:", item: item)
    }

    static func setPresence(identifier: String, visible: Bool) {
        guard let function = loadSetPresenceFunctionIfNeeded() else {
            return
        }
        function(identifier as NSString, ObjCBool(visible))
    }

    private static func performItemClassSelector(_ selectorName: String, item: NSTouchBarItem) {
        let selector = NSSelectorFromString(selectorName)
        let target = NSTouchBarItem.self as AnyObject
        guard target.responds(to: selector) else {
            return
        }
        _ = target.perform(selector, with: item)
    }

    private static func loadSetPresenceFunctionIfNeeded() -> SetPresenceFunction? {
        if didLoadSetPresenceFunction {
            return setPresenceFunction
        }
        didLoadSetPresenceFunction = true

        let frameworkPath = "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation"
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            return nil
        }
        guard let symbol = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") else {
            return nil
        }
        setPresenceFunction = unsafeBitCast(symbol, to: SetPresenceFunction.self)
        return setPresenceFunction
    }
}

private final class TouchBarQuotaView: NSView {
    private let stack = NSStackView()
    private let claudeView = ProviderQuotaView(title: "Claude")
    private let codexView = ProviderQuotaView(title: "Codex")

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 690, height: 30))
        setupViews()
        render(claudeSnapshot: nil, codexSnapshot: nil, mode: .both, language: .english)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        claudeSnapshot: QuotaSnapshot?,
        codexSnapshot: QuotaSnapshot?,
        mode: TouchBarProviderMode,
        language: WidgetLanguage
    ) {
        // Only show the Claude segment when there is a fresh snapshot, i.e. when
        // Claude Code is actually running and has produced quota data. Otherwise
        // hide it entirely instead of showing a "--%" placeholder.
        syncProviders(
            showClaude: mode.showsClaude && claudeSnapshot != nil,
            showCodex: mode.showsCodex
        )
        claudeView.render(snapshot: claudeSnapshot, language: language)
        codexView.render(snapshot: codexSnapshot, language: language)
    }

    private func setupViews() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([claudeView, codexView], in: .leading)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func syncProviders(showClaude: Bool, showCodex: Bool) {
        var views: [NSView] = []
        if showClaude {
            views.append(claudeView)
        }
        if showCodex {
            views.append(codexView)
        }

        if stack.arrangedSubviews != views {
            stack.setViews(views, in: .leading)
        }
    }
}

private final class ProviderQuotaView: NSView {
    private let titleLabel: NSTextField
    private let fiveHourRow = TouchBarQuotaRow()
    private let sevenDayRow = TouchBarQuotaRow()

    init(title: String) {
        self.titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        setupViews()
        render(snapshot: nil, language: .english)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(snapshot: QuotaSnapshot?, language: WidgetLanguage) {
        let windows = snapshot.map(normalizedWindows(from:)) ?? (fiveHour: nil, sevenDay: nil)
        fiveHourRow.render(label: "5h", quota: windows.fiveHour, resetStyle: .time, language: language)
        sevenDayRow.render(label: "7D", quota: windows.sevenDay, resetStyle: .date, language: language)
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let rows = NSStackView(views: [fiveHourRow, sevenDayRow])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        rows.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [titleLabel, rows])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            titleLabel.widthAnchor.constraint(equalToConstant: 48),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func normalizedWindows(from snapshot: QuotaSnapshot) -> (fiveHour: WindowQuota?, sevenDay: WindowQuota?) {
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        let fiveHour = windows.first { $0.label == "5h" }
        let sevenDay = windows.first { $0.label == "7d" }
        return (fiveHour, sevenDay)
    }
}

private final class TouchBarQuotaRow: NSView {
    private let nameLabel = NSTextField(labelWithString: "--")
    private let barView = SegmentedQuotaBarView()
    private let percentLabel = NSTextField(labelWithString: "--%")
    private let resetLabel = NSTextField(labelWithString: "--")

    init() {
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(label: String, quota: WindowQuota?, resetStyle: ResetStyle, language: WidgetLanguage) {
        nameLabel.stringValue = label
        let remaining = quota?.remainingPercent
        let roundedPercent = remaining.map { Int($0.rounded()) }
        percentLabel.stringValue = roundedPercent.map { "\($0)%" } ?? "--%"
        resetLabel.stringValue = TouchBarQuotaFormatter.resetText(quota?.resetsAt, style: resetStyle, language: language)
        barView.render(remainingPercent: remaining)
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        [nameLabel, percentLabel, resetLabel].forEach { label in
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = NSColor.white.withAlphaComponent(0.9)
            label.lineBreakMode = .byClipping
            label.translatesAutoresizingMaskIntoConstraints = false
        }

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        resetLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        resetLabel.textColor = NSColor.white.withAlphaComponent(0.7)

        let stack = NSStackView(views: [nameLabel, barView, percentLabel, resetLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            nameLabel.widthAnchor.constraint(equalToConstant: 22),
            barView.widthAnchor.constraint(equalToConstant: 88),
            barView.heightAnchor.constraint(equalToConstant: 8),
            percentLabel.widthAnchor.constraint(equalToConstant: 36),
            resetLabel.widthAnchor.constraint(equalToConstant: 70),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

private final class SegmentedQuotaBarView: NSView {
    private let segmentCount = 14
    private var activeSegments = 0
    private var activeColor = WidgetColors.mutedColor

    func render(remainingPercent: Double?) {
        let remaining = remainingPercent ?? 0
        activeSegments = Int((remaining / 100 * Double(segmentCount)).rounded())
        activeSegments = min(max(activeSegments, 0), segmentCount)
        activeColor = remainingPercent == nil ? WidgetColors.mutedColor : WidgetColors.color(for: remaining)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let gap: CGFloat = 2
        let segmentWidth = (bounds.width - CGFloat(segmentCount - 1) * gap) / CGFloat(segmentCount)
        let segmentHeight = bounds.height

        for index in 0..<segmentCount {
            let rect = NSRect(
                x: CGFloat(index) * (segmentWidth + gap),
                y: 0,
                width: segmentWidth,
                height: segmentHeight
            )

            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            let color = index < activeSegments
                ? activeColor
                : NSColor.white.withAlphaComponent(0.18)
            color.setFill()
            path.fill()
        }
    }
}

private enum ResetStyle {
    case time
    case date
}

private enum TouchBarQuotaFormatter {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    static func resetText(_ date: Date?, style: ResetStyle, language _: WidgetLanguage) -> String {
        guard let date else {
            return "-- · --"
        }

        switch style {
        case .time:
            let time = timeFormatter.string(from: date)
            return "\(time) · \(countdownText(until: date, style: .time))"
        case .date:
            let dateText = dateFormatter.string(from: date)
            return "\(dateText) · \(countdownText(until: date, style: .date))"
        }
    }

    private static func countdownText(until date: Date, style: ResetStyle) -> String {
        let remainingSeconds = max(0, Int(date.timeIntervalSinceNow))
        let days = remainingSeconds / 86_400
        let hours = (remainingSeconds % 86_400) / 3_600
        let minutes = (remainingSeconds % 3_600) / 60

        switch style {
        case .time:
            if hours > 0 {
                return "\(hours)h\(minutes)m"
            }
            return "\(max(minutes, 0))m"
        case .date:
            if days > 0 {
                return "\(days)d\(hours)h"
            }
            if hours > 0 {
                return "\(hours)h\(minutes)m"
            }
            return "\(max(minutes, 0))m"
        }
    }
}
