import Foundation

@MainActor
final class ReclaimHistoryStore {
    private struct Record: Codable {
        let candidateID: String
        let cleanedAt: Date
        let removedBytes: Int64
        let postCleanupFootprint: Int64
        let mode: String
    }

    private struct Archive: Codable {
        let version: Int
        var records: [Record]
    }

    private let fileURL: URL
    private var records: [String: Record] = [:]

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    func enrich(_ candidate: CleanupCandidate) -> CleanupCandidate {
        guard let record = records[candidate.id], record.removedBytes > 0 else { return candidate }
        let regrown = max(0, candidate.currentFootprint - record.postCleanupFootprint)
        let retained = max(0, min(record.removedBytes, record.removedBytes - regrown))
        var enriched = candidate
        enriched.reclaimEvidence = ReclaimEvidence(
            cleanedAt: record.cleanedAt,
            removedBytes: record.removedBytes,
            retainedBytes: retained
        )
        return enriched
    }

    func record(_ result: CleanupResult, mode: CleanupMode, at date: Date = Date()) {
        for outcome in result.outcomes where outcome.disposition == .deleted && outcome.removedBytes > 0 {
            records[outcome.candidateID] = Record(
                candidateID: outcome.candidateID,
                cleanedAt: date,
                removedBytes: outcome.removedBytes,
                postCleanupFootprint: outcome.remainingFootprint,
                mode: mode.rawValue
            )
        }
        if records.count > 500 {
            let retained = records.values.sorted { $0.cleanedAt > $1.cleanedAt }.prefix(500)
            records = Dictionary(uniqueKeysWithValues: retained.map { ($0.candidateID, $0) })
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(Archive.self, from: data), archive.version == 1 else { return }
        records = Dictionary(uniqueKeysWithValues: archive.records.map { ($0.candidateID, $0) })
    }

    private func save() {
        let archive = Archive(version: 1, records: Array(records.values))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(archive) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Cleanup history is optional; a failed write must never block cleanup.
        }
    }

    private static func defaultFileURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WaxOnWaxOff", isDirectory: true)
            .appendingPathComponent("reclaim-history.json")
    }
}
