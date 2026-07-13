import Foundation

/// Breakdown of the volume's storage allocation, computed from sandbox-safe URLResourceKey APIs.
/// After an analysis pass, the balance can be enriched with reclaimable and scanned totals.
struct StorageBalance: Sendable {
    let totalCapacity: Int64
    let physicalFree: Int64
    let availableForImportant: Int64
    let availableForOpportunistic: Int64

    // Post-analysis enrichment (set after engine.analyze completes).
    var scannedHomeSize: Int64?
    var reclaimableByApp: Int64 = 0
    var protectedInHome: Int64?
    var candidateCount: Int = 0

    // MARK: Derived

    var purgeableSpace: Int64 { max(0, availableForImportant - physicalFree) }
    var usedSpace: Int64 { max(0, totalCapacity - physicalFree) }
    var usedPercent: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(usedSpace) / Double(totalCapacity)
    }
    var freePercent: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(physicalFree) / Double(totalCapacity)
    }
    var purgeablePercent: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(purgeableSpace) / Double(totalCapacity)
    }
    var reclaimablePercent: Double {
        guard totalCapacity > 0 else { return 0 }
        return Double(reclaimableByApp) / Double(totalCapacity)
    }

    /// Estimated free space after applying selected cleanup.
    var projectedFreeAfterCleanup: Int64 { min(totalCapacity, physicalFree + reclaimableByApp) }

    /// Fraction of currently-used space that the app can reclaim.
    var reclaimEfficiency: Double {
        guard usedSpace > 0 else { return 0 }
        return Double(reclaimableByApp) / Double(usedSpace)
    }
}

/// Queries volume capacity using only sandbox-safe URLResourceKey APIs.
/// These keys are already covered by the Privacy Manifest (DiskSpace reason E174.1).
enum StorageBalanceAnalyzer {
    /// Compute the storage balance for the volume containing `url`.
    static func analyze(volumeAt url: URL) -> StorageBalance? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }

        let total = Int64(values.volumeTotalCapacity ?? 0)
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(free)
        let opportunistic = values.volumeAvailableCapacityForOpportunisticUsage ?? important

        guard total > 0 else { return nil }

        return StorageBalance(
            totalCapacity: total,
            physicalFree: free,
            availableForImportant: important,
            availableForOpportunistic: opportunistic
        )
    }

    /// Enrich a balance with post-analysis candidate data.
    static func enrich(
        _ balance: StorageBalance,
        selectedBytes: Int64,
        candidateCount: Int,
        scannedHomeSize: Int64? = nil,
        protectedInHome: Int64? = nil
    ) -> StorageBalance {
        var enriched = balance
        if let scannedHomeSize {
            enriched.scannedHomeSize = scannedHomeSize
        }
        if let protectedInHome {
            enriched.protectedInHome = protectedInHome
        }
        enriched.reclaimableByApp = selectedBytes
        enriched.candidateCount = candidateCount
        return enriched
    }
}
