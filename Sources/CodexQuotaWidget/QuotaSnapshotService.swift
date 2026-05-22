import Foundation

final class QuotaSnapshotService {
    private let sessionDirectory: URL
    private let appServerProvider: CodexAppServerQuotaProvider
    private let decoderFormatter: ISO8601DateFormatter
    private let fallbackFormatter: ISO8601DateFormatter
    private var cachedSignature: String?
    private var cachedLogSnapshot: QuotaSnapshot?
    private var lastValidSnapshot: QuotaSnapshot?

    init(
        sessionDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        appServerProvider: CodexAppServerQuotaProvider = CodexAppServerQuotaProvider()
    ) {
        self.sessionDirectory = sessionDirectory
        self.appServerProvider = appServerProvider
        self.decoderFormatter = ISO8601DateFormatter()
        self.decoderFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fallbackFormatter = ISO8601DateFormatter()
        self.fallbackFormatter.formatOptions = [.withInternetDateTime]
    }

    func latestSnapshot(forceReload: Bool = false) -> QuotaSnapshot? {
        if let snapshot = appServerProvider.latestSnapshot() {
            lastValidSnapshot = snapshot
            return snapshot
        }

        if let snapshot = latestLogSnapshot(forceReload: forceReload) {
            lastValidSnapshot = snapshot
            return snapshot
        }

        return lastValidSnapshot
    }

    func stop() {
        appServerProvider.stop()
    }

    private func latestLogSnapshot(forceReload: Bool = false) -> QuotaSnapshot? {
        let files = newestSessionFiles(limit: 120)
        let signature = files
            .map { "\($0.url.path)::\($0.modifiedAt.timeIntervalSince1970)::\($0.fileSize)" }
            .joined(separator: "|")

        if !forceReload, signature == cachedSignature {
            return cachedLogSnapshot
        }

        let snapshot = files
            .map(\.url)
            .compactMap(parseSnapshotWithReferenceDate(from:))
            .max { lhs, rhs in
                if lhs.referenceDate == rhs.referenceDate {
                    return lhs.fileModifiedAt < rhs.fileModifiedAt
                }
                return lhs.referenceDate < rhs.referenceDate
            }?
            .snapshot

        cachedSignature = signature
        if let snapshot {
            cachedLogSnapshot = snapshot
            return snapshot
        }
        return cachedLogSnapshot
    }

    private func newestSessionFiles(limit: Int) -> [(url: URL, modifiedAt: Date, fileSize: UInt64)] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date, fileSize: UInt64)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            files.append((fileURL, values?.contentModificationDate ?? .distantPast, UInt64(values?.fileSize ?? 0)))
        }

        return files
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map { $0 }
    }

    private func parseSnapshotWithReferenceDate(from fileURL: URL) -> SnapshotCandidate? {
        let lines = recentLines(from: fileURL, maxBytes: 4 * 1024 * 1024)
        let fileModifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast

        for rawLine in lines.reversed() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else { continue }
            guard
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                payload["type"] as? String == "event_msg",
                let innerPayload = payload["payload"] as? [String: Any],
                innerPayload["type"] as? String == "token_count",
                let rateLimits = innerPayload["rate_limits"] as? [String: Any],
                let primaryPayload = rateLimits["primary"] as? [String: Any],
                let primary = parseWindow(primaryPayload)
            else {
                continue
            }

            let secondary = (rateLimits["secondary"] as? [String: Any]).flatMap(parseWindow(_:))
            let timestamp = parseTimestamp(payload["timestamp"] as? String)

            let snapshot = QuotaSnapshot(
                sourceFileName: fileURL.lastPathComponent,
                eventTimestamp: timestamp,
                detectedAt: Date(),
                planType: rateLimits["plan_type"] as? String,
                primary: primary,
                secondary: secondary
            )

            let candidate = SnapshotCandidate(
                snapshot: snapshot,
                referenceDate: timestamp ?? fileModifiedAt,
                fileModifiedAt: fileModifiedAt
            )

            let limitId = (rateLimits["limit_id"] as? String)?.lowercased()
            guard limitId == "codex" else { continue }
            return candidate
        }

        return nil
    }

    private func parseWindow(_ payload: [String: Any]) -> WindowQuota? {
        guard let windowMinutes = payload["window_minutes"] as? Int ?? Int("\(payload["window_minutes"] ?? "")") else {
            return nil
        }

        let usedPercent = clampPercent(payload["used_percent"])
        let resetsEpoch = payload["resets_at"] as? Int ?? Int("\(payload["resets_at"] ?? "")")

        return WindowQuota(
            label: windowLabel(minutes: windowMinutes),
            usedPercent: usedPercent,
            remainingPercent: max(0, 100 - usedPercent),
            resetsAt: resetsEpoch.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private func clampPercent(_ value: Any?) -> Double {
        guard let value else { return 0 }
        let number = (value as? NSNumber)?.doubleValue ?? Double("\(value)") ?? 0
        return min(max(number, 0), 100)
    }

    private func recentLines(from fileURL: URL, maxBytes: Int) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return []
        }
        defer { try? handle.close() }

        let totalBytes = (try? handle.seekToEnd()) ?? 0
        let readOffset = totalBytes > UInt64(maxBytes) ? totalBytes - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: readOffset)

        var data = handle.readDataToEndOfFile()
        if readOffset > 0, let newlineRange = data.range(of: Data([0x0A])) {
            data = data.subdata(in: newlineRange.upperBound..<data.count)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.components(separatedBy: .newlines)
    }

    private func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let value = decoderFormatter.date(from: raw) {
            return value
        }
        return fallbackFormatter.date(from: raw)
    }

    private func windowLabel(minutes: Int) -> String {
        switch minutes {
        case 300:
            return "5h"
        case 10080:
            return "7d"
        case let value where value % 1440 == 0:
            return "\(value / 1440)d"
        case let value where value % 60 == 0:
            return "\(value / 60)h"
        default:
            return "\(minutes)m"
        }
    }
}

private struct SnapshotCandidate {
    let snapshot: QuotaSnapshot
    let referenceDate: Date
    let fileModifiedAt: Date
}
