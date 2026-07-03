import Foundation

struct WindowQuota: Codable {
    let label: String
    let usedPercent: Double
    let remainingPercent: Double
    let resetsAt: Date?
}

struct QuotaSnapshot: Codable {
    let providerName: String?
    let sourceFileName: String
    let eventTimestamp: Date?
    let detectedAt: Date
    let planType: String?
    let primary: WindowQuota
    let secondary: WindowQuota?
}

struct WidgetState: Codable {
    var widgetEnabled: Bool?
    var originX: Double?
    var originY: Double?
    var language: WidgetLanguage?
    var capsuleEnabled: Bool?
    var touchBarProviderMode: TouchBarProviderMode?
    // When true, keep the quota view pinned on the Touch Bar regardless of which
    // app is in the foreground (re-assert it on every app switch). When
    // false/unset, the Touch Bar is yielded to the foreground app after a switch.
    var touchBarPinned: Bool?
    // Optional foreground app allowlist. Entries match either bundle identifier
    // or localized app name, case-insensitively. Empty/unset means all apps.
    var touchBarAppFilters: [String]?
}

enum TouchBarProviderMode: String, Codable {
    case both
    case codex
    case claude

    var showsCodex: Bool {
        self == .both || self == .codex
    }

    var showsClaude: Bool {
        self == .both || self == .claude
    }
}

enum WidgetLanguage: String, Codable {
    case english
    case chinese

    var toggled: WidgetLanguage {
        switch self {
        case .english:
            return .chinese
        case .chinese:
            return .english
        }
    }

    var menuTitle: String {
        switch self {
        case .english:
            return "Language: English"
        case .chinese:
            return "Language: 中文"
        }
    }
}

enum RefreshCadence {
    case hidden
    case fast
    case normal

    var interval: TimeInterval {
        switch self {
        case .hidden:
            return 5
        case .fast:
            return 1
        case .normal:
            return 2
        }
    }
}
