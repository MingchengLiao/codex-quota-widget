import Foundation

struct WindowQuota: Codable {
    let label: String
    let usedPercent: Double
    let remainingPercent: Double
    let resetsAt: Date?
}

struct QuotaSnapshot: Codable {
    let sourceFileName: String
    let eventTimestamp: Date?
    let detectedAt: Date
    let planType: String?
    let primary: WindowQuota
    let secondary: WindowQuota?
}

struct WidgetState: Codable {
    var originX: Double?
    var originY: Double?
    var language: WidgetLanguage?
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
