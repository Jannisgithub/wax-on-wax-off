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
    private var recordsByCandidate: [String: [Record]] = [:]

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
    }

    func enrich(_ candidate: CleanupCandidate) -> CleanupCandidate {
        var enriched = candidate
        if let record = latestRecord(for: candidate.id), record.removedBytes > 0 {
            let retained = retainedBytes(from: record, currentFootprint: candidate.currentFootprint)
            enriched.reclaimEvidence = ReclaimEvidence(
                cleanedAt: record.cleanedAt,
                removedBytes: record.removedBytes,
                retainedBytes: retained
            )
        }
        enriched.regrowthPrediction = prediction(
            for: candidate.id,
            currentFootprint: candidate.currentFootprint
        )
        return enriched
    }

    func prediction(for candidateID: String, currentFootprint: Int64) -> RegrowthPrediction? {
        let rates = retentionRates(for: candidateID, currentFootprint: currentFootprint)
        guard !rates.isEmpty else { return nil }

        let alpha = 2 / Double(rates.count + 1)
        let ema = rates.dropFirst().reduce(rates[0]) { partial, rate in
            alpha * rate + (1 - alpha) * partial
        }
        let average = rates.reduce(0, +) / Double(rates.count)

        return RegrowthPrediction(
            predictedRetentionRate: clamp(ema),
            confidence: confidence(cleanupCount: rates.count),
            historicalCleanups: rates.count,
            averageRetainedPercent: clamp(average),
            trend: trend(for: rates)
        )
    }

    func record(_ result: CleanupResult, mode: CleanupMode, at date: Date = Date()) {
        for outcome in result.outcomes where outcome.disposition == .deleted && outcome.removedBytes > 0 {
            var records = recordsByCandidate[outcome.candidateID, default: []]
            records.append(Record(
                candidateID: outcome.candidateID,
                cleanedAt: date,
                removedBytes: outcome.removedBytes,
                postCleanupFootprint: outcome.remainingFootprint,
                mode: mode.rawValue
            ))
            recordsByCandidate[outcome.candidateID] = Array(records.sorted { $0.cleanedAt < $1.cleanedAt }.suffix(12))
        }
        trimToMaximumRecordCount()
        save()
    }

    func recentCleanupTotals(limit: Int = 7) -> [Int64] {
        guard limit > 0 else { return [] }
        let records = recordsByCandidate.values.flatMap { $0 }
        let totalsByDate = Dictionary(grouping: records, by: \.cleanedAt).map { date, records in
            (date: date, bytes: records.reduce(Int64(0)) { $0 + $1.removedBytes })
        }

        return totalsByDate
            .filter { $0.bytes > 0 }
            .sorted { $0.date < $1.date }
            .suffix(limit)
            .map(\.bytes)
    }

    func reset() {
        recordsByCandidate = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func latestRecord(for candidateID: String) -> Record? {
        recordsByCandidate[candidateID]?.max { $0.cleanedAt < $1.cleanedAt }
    }

    private func retainedBytes(from record: Record, currentFootprint: Int64) -> Int64 {
        let regrown = max(0, currentFootprint - record.postCleanupFootprint)
        return max(0, min(record.removedBytes, record.removedBytes - regrown))
    }

    private func retentionRates(for candidateID: String, currentFootprint: Int64) -> [Double] {
        let records = (recordsByCandidate[candidateID] ?? []).sorted { $0.cleanedAt < $1.cleanedAt }
        guard !records.isEmpty else { return [] }

        return records.enumerated().compactMap { index, record in
            guard record.removedBytes > 0 else { return nil }
            let observedFootprint: Int64
            if records.indices.contains(index + 1) {
                let next = records[index + 1]
                observedFootprint = next.postCleanupFootprint + next.removedBytes
            } else {
                observedFootprint = currentFootprint
            }
            return Double(retainedBytes(from: record, currentFootprint: observedFootprint)) / Double(record.removedBytes)
        }
    }

    private func confidence(cleanupCount: Int) -> Double {
        switch cleanupCount {
        case 0:
            0
        case 1:
            0.3
        case 2:
            0.6
        case 3...4:
            0.85
        default:
            0.95
        }
    }

    private func trend(for rates: [Double]) -> RegrowthPrediction.Trend {
        let window = Array(rates.suffix(5))
        guard window.count >= 3 else { return .stable }

        let count = Double(window.count)
        let xMean = Double(window.count - 1) / 2
        let yMean = window.reduce(0, +) / count
        let numerator = window.enumerated().reduce(0) { partial, item in
            let x = Double(item.offset)
            return partial + (x - xMean) * (item.element - yMean)
        }
        let denominator = window.indices.reduce(0) { partial, index in
            let x = Double(index)
            return partial + (x - xMean) * (x - xMean)
        }
        guard denominator > 0 else { return .stable }

        let slope = numerator / denominator
        if slope > 0.03 { return .improving }
        if slope < -0.03 { return .degrading }
        return .stable
    }

    private func trimToMaximumRecordCount() {
        let retained = recordsByCandidate.values
            .flatMap { $0 }
            .sorted { $0.cleanedAt > $1.cleanedAt }
            .prefix(500)
        var grouped: [String: [Record]] = [:]
        for record in retained {
            grouped[record.candidateID, default: []].append(record)
        }
        recordsByCandidate = grouped.mapValues { $0.sorted { $0.cleanedAt < $1.cleanedAt } }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(Archive.self, from: data),
              archive.version == 1 || archive.version == 2 else {
            return
        }

        var grouped: [String: [Record]] = [:]
        for record in archive.records where record.removedBytes > 0 {
            grouped[record.candidateID, default: []].append(record)
        }
        recordsByCandidate = grouped.mapValues { $0.sorted { $0.cleanedAt < $1.cleanedAt } }
    }

    private func save() {
        let archive = Archive(
            version: 2,
            records: recordsByCandidate.values
                .flatMap { $0 }
                .sorted { $0.cleanedAt < $1.cleanedAt }
        )
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

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
