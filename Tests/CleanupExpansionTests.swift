import XCTest
@testable import WaxOnWaxOff

final class CleanupExpansionTests: XCTestCase {
    func testHighPolicyAddsBroaderCachesWithUncertainTargetsUnchecked() {
        let targets = Dictionary(uniqueKeysWithValues: CleanupPolicy.targets(for: .high).map { ($0.id, $0) })
        XCTAssertNotNil(targets["yarn-cache"])
        XCTAssertNotNil(targets["pnpm-cache"])
        XCTAssertNotNil(targets["cocoapods-cache"])
        XCTAssertNotNil(targets["cargo-download-cache"])
        XCTAssertNotNil(targets["go-build-cache"])
        XCTAssertTrue(CleanupPolicy.developerCaches.allSatisfy { !$0.defaultSelected })
        XCTAssertEqual(targets["go-module-downloads"]?.defaultSelected, false)
        XCTAssertEqual(targets["gradle-distributions"]?.defaultSelected, false)
        XCTAssertEqual(CleanupMode.high.ageDays, CleanupMode.mid.ageDays)
    }

    func testHighRecommendsMidWhenAdditionalCleanupIsSmall() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let report = await CleanupEngine().analyze(mode: .high, home: home, runningBundleIDs: [])
        XCTAssertTrue(report.warnings.contains { $0.contains("MID is recommended") })
    }

    func testNamedHighCacheIsExcludedFromBroadUserCacheCandidate() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let pip = home.appendingPathComponent("Library/Caches/pip", isDirectory: true)
        try FileManager.default.createDirectory(at: pip, withIntermediateDirectories: true)
        let file = pip.appendingPathComponent("package.whl")
        try Data(repeating: 9, count: 4_096).write(to: file)
        try setAge(days: 40, for: file)

        let report = await CleanupEngine().analyze(mode: .high, home: home, runningBundleIDs: [])
        XCTAssertTrue(report.candidates.contains { $0.id == "pip-cache" })
        XCTAssertFalse(report.candidates.contains { $0.id == "user-caches" })
    }

    func testHighDoesNotScanProjectDirectories() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let project = home.appendingPathComponent("Projects/App", isDirectory: true)
        let modules = project.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        try Data("lock".utf8).write(to: project.appendingPathComponent("pnpm-lock.yaml"))
        try Data(repeating: 1, count: 4_096).write(to: modules.appendingPathComponent("dependency.bin"))

        let report = await CleanupEngine().analyze(mode: .high, home: home, runningBundleIDs: [])
        XCTAssertFalse(report.candidates.contains { $0.label == "JavaScript dependencies" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: modules.path))
    }

    func testAppSupportScanDeletesRenderCacheButPreservesPersistentStorage() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let slack = home.appendingPathComponent("Library/Application Support/Slack", isDirectory: true)
        let cache = slack.appendingPathComponent("Cache", isDirectory: true)
        let storage = slack.appendingPathComponent("Local Storage", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 4_096).write(to: cache.appendingPathComponent("cache.bin"))
        try Data(repeating: 4, count: 4_096).write(to: storage.appendingPathComponent("state.bin"))

        let engine = CleanupEngine()
        let report = await engine.analyze(mode: .high, home: home, runningBundleIDs: [])
        let candidate = try XCTUnwrap(report.candidates.first { $0.id == "slack-render" })
        XCTAssertFalse(candidate.defaultSelected)

        let result = await engine.apply(candidates: [candidate], home: home)
        XCTAssertEqual(result.removedItems, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.path))
    }

    func testRunningAppSuppressesAppSupportCache() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Application Support/Slack/Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 4_096).write(to: cache.appendingPathComponent("cache.bin"))

        let report = await CleanupEngine().analyze(
            mode: .high,
            home: home,
            runningBundleIDs: ["com.tinyspeck.slackmacgap.helper.GPU"]
        )
        XCTAssertFalse(report.candidates.contains { $0.id == "slack-render" })
        XCTAssertTrue(report.warnings.contains { $0.contains("Slack render caches") })
    }

    func testOldInstallerIsUncheckedReviewCandidateForTrash() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let installer = downloads.appendingPathComponent("OldTool.dmg")
        try Data(repeating: 6, count: 4_096).write(to: installer)
        try setAge(days: 40, for: installer)

        let engine = CleanupEngine(minimumInstallerBytes: 1)
        let report = await engine.analyze(mode: .high, home: home, runningBundleIDs: [])
        let candidate = try XCTUnwrap(report.candidates.first { $0.label == "OldTool.dmg" })
        XCTAssertEqual(candidate.risk, .review)
        XCTAssertFalse(candidate.defaultSelected)
        if case .recycle = candidate.operation {
            // Expected: reviewed user files are recoverable.
        } else {
            XCTFail("Old installers must move to Trash")
        }
    }

    func testMavenCleanupPreservesLocallyInstalledArtifact() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let version = home.appendingPathComponent(".m2/repository/com/example/tool/1.0", isDirectory: true)
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        let remote = version.appendingPathComponent("tool-1.0.jar")
        let local = version.appendingPathComponent("local-only.jar")
        let marker = version.appendingPathComponent("_remote.repositories")
        try Data(repeating: 7, count: 4_096).write(to: remote)
        try Data(repeating: 8, count: 4_096).write(to: local)
        try Data("tool-1.0.jar>central=\nlocal-only.jar>=".utf8).write(to: marker)
        try setAge(days: 20, for: remote)
        try setAge(days: 20, for: local)
        try setAge(days: 20, for: marker)

        let engine = CleanupEngine()
        let report = await engine.analyze(mode: .high, home: home, runningBundleIDs: [])
        let candidate = try XCTUnwrap(report.candidates.first { $0.id == "maven-remote-cache" })
        _ = await engine.apply(candidates: [candidate], home: home)

        XCTAssertFalse(FileManager.default.fileExists(atPath: remote.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
    }

    @MainActor
    func testFolderAuthorizationAcceptsOnlyCurrentHome() throws {
        let alternate = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotAHome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: alternate.appendingPathComponent("Library", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: alternate) }

        let manager = FolderAccessManager()
        let accountHome = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(manager.isExpectedHomeSelection(accountHome))
        let dataVolumeHome = URL(fileURLWithPath: "/System/Volumes/Data" + accountHome.path, isDirectory: true)
        if FileManager.default.fileExists(atPath: dataVolumeHome.path) {
            XCTAssertTrue(manager.isExpectedHomeSelection(dataVolumeHome))
        }
        XCTAssertFalse(manager.isExpectedHomeSelection(alternate))
        XCTAssertFalse(manager.isExpectedHomeSelection(URL(fileURLWithPath: "/", isDirectory: true)))
        XCTAssertFalse(manager.isExpectedHomeSelection(URL(fileURLWithPath: "/Users", isDirectory: true)))

        for name in ["Desktop", "Documents"] {
            try FileManager.default.createDirectory(
                at: alternate.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        XCTAssertFalse(manager.isExpectedHomeSelection(alternate))
    }

    @MainActor
    func testReclaimHistoryCalculatesRetainedSpaceWithoutStoringPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let historyURL = directory.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReclaimHistoryStore(fileURL: historyURL)
        let result = CleanupResult(
            removedBytes: 1_000,
            removedItems: 1,
            skippedItems: 0,
            warnings: [],
            outcomes: [CandidateCleanupOutcome(
                candidateID: "cache-id",
                removedBytes: 1_000,
                remainingFootprint: 100,
                disposition: .deleted
            )]
        )
        store.record(result, mode: .high, at: Date(timeIntervalSince1970: 1_000))

        let candidate = CleanupCandidate(
            id: "cache-id",
            label: "Cache",
            detail: "Test",
            size: 300,
            itemCount: 1,
            risk: .confirm,
            defaultSelected: true,
            operation: .recommendation,
            currentFootprint: 300
        )
        let enriched = store.enrich(candidate)
        XCTAssertEqual(enriched.reclaimEvidence?.retainedBytes, 800)
        XCTAssertEqual(enriched.reclaimEvidence?.retainedPercent, 80)
        let serialized = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(serialized.contains("/Users/"))
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaxOnWaxOffExpansionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setAge(days: Int, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: TimeInterval(-days * 86_400))],
            ofItemAtPath: url.path
        )
    }
}
