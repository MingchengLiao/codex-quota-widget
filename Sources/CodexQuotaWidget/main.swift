import AppKit
import Darwin
import Foundation

func writeStdout(_ text: String) {
    FileHandle.standardOutput.write(text.data(using: .utf8)!)
}

func writeStderr(_ text: String) {
    FileHandle.standardError.write(text.data(using: .utf8)!)
}

func printUsage() {
    writeStdout("""
    Usage:
      CodexQuotaWidget
      CodexQuotaWidget --once
      CodexQuotaWidget --settings
      CodexQuotaWidget --widget on|off
      CodexQuotaWidget --capsule on|off
      CodexQuotaWidget --providers codex|claude|both
      CodexQuotaWidget --touchbar-pin on|off
      CodexQuotaWidget --touchbar-apps list|clear|<bundle-id-or-app-name> [...]

    """)
}

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") {
    printUsage()
    exit(EXIT_SUCCESS)
}

if arguments.first == "--settings" {
    let state = WidgetStateStore().load()
    let claudeSnapshot = ClaudeCodeSnapshotService().latestSnapshot()
    let payload: [String: Any] = [
        "capsuleEnabled": state.capsuleEnabled ?? true,
        "claudeSnapshotFresh": claudeSnapshot != nil,
        "language": (state.language ?? .english).rawValue,
        "touchBarAppFilters": state.touchBarAppFilters ?? [],
        "touchBarPinned": state.touchBarPinned ?? false,
        "touchBarProviderMode": (state.touchBarProviderMode ?? .both).rawValue,
        "widgetEnabled": state.widgetEnabled ?? true,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
        writeStderr("Failed to encode settings.\n")
        exit(EXIT_FAILURE)
    }
    FileHandle.standardOutput.write(data)
    writeStdout("\n")
    exit(EXIT_SUCCESS)
}

if arguments.first == "--widget" {
    guard arguments.count == 2 else {
        writeStderr("Usage: CodexQuotaWidget --widget on|off\n")
        exit(EX_USAGE)
    }

    let enabled: Bool
    switch arguments[1].lowercased() {
    case "on", "enable", "enabled", "true", "1":
        enabled = true
    case "off", "disable", "disabled", "false", "0":
        enabled = false
    default:
        writeStderr("Usage: CodexQuotaWidget --widget on|off\n")
        exit(EX_USAGE)
    }

    WidgetStateStore().update { state in
        state.widgetEnabled = enabled
    }
    writeStdout("Widget \(enabled ? "enabled" : "disabled"). Restart the helper to apply if it is already running.\n")
    exit(EXIT_SUCCESS)
}

if arguments.first == "--capsule" {
    guard arguments.count == 2 else {
        writeStderr("Usage: CodexQuotaWidget --capsule on|off\n")
        exit(EX_USAGE)
    }

    let enabled: Bool
    switch arguments[1].lowercased() {
    case "on", "enable", "enabled", "true", "1":
        enabled = true
    case "off", "disable", "disabled", "false", "0":
        enabled = false
    default:
        writeStderr("Usage: CodexQuotaWidget --capsule on|off\n")
        exit(EX_USAGE)
    }

    WidgetStateStore().update { state in
        state.capsuleEnabled = enabled
    }
    writeStdout("Capsule \(enabled ? "enabled" : "disabled"). Restart the helper to apply if it is already running.\n")
    exit(EXIT_SUCCESS)
}

if arguments.first == "--providers" {
    guard arguments.count == 2 else {
        writeStderr("Usage: CodexQuotaWidget --providers codex|claude|both\n")
        exit(EX_USAGE)
    }

    guard let mode = TouchBarProviderMode(rawValue: arguments[1].lowercased()) else {
        writeStderr("Usage: CodexQuotaWidget --providers codex|claude|both\n")
        exit(EX_USAGE)
    }

    WidgetStateStore().update { state in
        state.touchBarProviderMode = mode
    }
    writeStdout("Touch Bar providers set to \(mode.rawValue). Restart the helper to apply if it is already running.\n")
    exit(EXIT_SUCCESS)
}

if arguments.first == "--touchbar-pin" {
    guard arguments.count == 2 else {
        writeStderr("Usage: CodexQuotaWidget --touchbar-pin on|off\n")
        exit(EX_USAGE)
    }

    let enabled: Bool
    switch arguments[1].lowercased() {
    case "on", "enable", "enabled", "true", "1":
        enabled = true
    case "off", "disable", "disabled", "false", "0":
        enabled = false
    default:
        writeStderr("Usage: CodexQuotaWidget --touchbar-pin on|off\n")
        exit(EX_USAGE)
    }

    WidgetStateStore().update { state in
        state.touchBarPinned = enabled
    }
    writeStdout("Touch Bar pin \(enabled ? "enabled" : "disabled"). Restart the helper to apply if it is already running.\n")
    exit(EXIT_SUCCESS)
}

if arguments.first == "--touchbar-apps" {
    guard arguments.count >= 2 else {
        writeStderr("Usage: CodexQuotaWidget --touchbar-apps list|clear|<bundle-id-or-app-name> [...]\n")
        exit(EX_USAGE)
    }

    let store = WidgetStateStore()
    let subcommand = arguments[1].lowercased()

    if subcommand == "list" {
        let filters = store.load().touchBarAppFilters ?? []
        if filters.isEmpty {
            writeStdout("Touch Bar app filter: all apps\n")
        } else {
            writeStdout("Touch Bar app filter:\n")
            for filter in filters {
                writeStdout("  \(filter)\n")
            }
        }
        exit(EXIT_SUCCESS)
    }

    if subcommand == "clear" || subcommand == "off" || subcommand == "all" {
        store.update { state in
            state.touchBarAppFilters = []
        }
        writeStdout("Touch Bar app filter cleared. Restart the helper to apply if it is already running.\n")
        exit(EXIT_SUCCESS)
    }

    let filters = Array(arguments.dropFirst())
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !filters.isEmpty else {
        writeStderr("Usage: CodexQuotaWidget --touchbar-apps list|clear|<bundle-id-or-app-name> [...]\n")
        exit(EX_USAGE)
    }

    store.update { state in
        state.touchBarAppFilters = filters
    }
    writeStdout("Touch Bar app filter set to:\n")
    for filter in filters {
        writeStdout("  \(filter)\n")
    }
    writeStdout("Restart the helper to apply if it is already running.\n")
    exit(EXIT_SUCCESS)
}

if CommandLine.arguments.contains("--once") {
    let snapshotService = QuotaSnapshotService()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    if let snapshot = snapshotService.latestSnapshot(), let data = try? encoder.encode(snapshot) {
        FileHandle.standardOutput.write(data)
        writeStdout("\n")
        exit(EXIT_SUCCESS)
    } else {
        writeStderr("No quota snapshot found in ~/.codex/sessions\n")
        exit(EXIT_FAILURE)
    }
}

if !arguments.isEmpty {
    printUsage()
    exit(EX_USAGE)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
