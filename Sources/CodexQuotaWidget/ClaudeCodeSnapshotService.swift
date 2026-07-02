import Foundation

final class ClaudeCodeSnapshotService {
    private let snapshotURL: URL
    private let maxAge: TimeInterval
    private let decoder = JSONDecoder()

    init(
        snapshotURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex-quota-widget/claude-code-snapshot.json"),
        // The bridge re-runs every ~10s (refreshInterval) while Claude Code is
        // open, so a 30s window keeps data live during use but hides the Claude
        // segment shortly after Claude Code is closed.
        maxAge: TimeInterval = 30
    ) {
        self.snapshotURL = snapshotURL
        self.maxAge = maxAge
        decoder.dateDecodingStrategy = .iso8601
    }

    func latestSnapshot() -> QuotaSnapshot? {
        guard
            let data = try? Data(contentsOf: snapshotURL),
            let snapshot = try? decoder.decode(QuotaSnapshot.self, from: data),
            Date().timeIntervalSince(snapshot.detectedAt) <= maxAge
        else {
            return nil
        }

        return snapshot
    }
}
