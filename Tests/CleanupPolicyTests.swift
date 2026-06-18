import XCTest
@testable import WaxOnWaxOff

final class CleanupPolicyTests: XCTestCase {
    func testLowUsesOnlyBaselineTargets() {
        XCTAssertEqual(CleanupPolicy.targets(for: .low).map(\.id), CleanupPolicy.baseline.map(\.id))
    }

    func testMidAddsAppCachesWithoutDeveloperCaches() {
        let ids = Set(CleanupPolicy.targets(for: .mid).map(\.id))
        XCTAssertTrue(ids.contains("chrome-models"))
        XCTAssertFalse(ids.contains("xcode-derived"))
    }

    func testHighAddsDeveloperCaches() {
        let ids = Set(CleanupPolicy.targets(for: .high).map(\.id))
        XCTAssertTrue(ids.contains("chrome-models"))
        XCTAssertTrue(ids.contains("xcode-derived"))
        XCTAssertTrue(ids.contains("npm-cache"))
    }

    func testModeAgeRules() {
        XCTAssertEqual(CleanupMode.low.ageDays, 30)
        XCTAssertEqual(CleanupMode.mid.ageDays, 14)
        XCTAssertEqual(CleanupMode.high.ageDays, 7)
        XCTAssertEqual(CleanupMode.leftovers.ageDays, 45)
    }

    func testLowAnalysisFindsAndDeletesOnlyOldFiles() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let cache = home.appendingPathComponent("Library/Caches/com.example.test", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let oldFile = cache.appendingPathComponent("old.cache")
        let recentFile = cache.appendingPathComponent("recent.cache")
        try Data(repeating: 1, count: 4_096).write(to: oldFile)
        try Data(repeating: 2, count: 4_096).write(to: recentFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -40 * 86_400)],
            ofItemAtPath: oldFile.path
        )

        let engine = CleanupEngine()
        let report = await engine.analyze(mode: .low, home: home, runningBundleIDs: [])
        XCTAssertEqual(report.candidates.map(\.id), ["user-caches"])
        XCTAssertEqual(report.candidates.first?.itemCount, 1)

        let result = await engine.apply(candidates: report.candidates, home: home)
        XCTAssertEqual(result.removedItems, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentFile.path))
    }

    func testAnalysisRejectsSymlinkedCleanupRoot() async throws {
        let home = try temporaryHome()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: library.appendingPathComponent("Caches"),
            withDestinationURL: outside
        )
        let outsideFile = outside.appendingPathComponent("must-stay.cache")
        try Data(repeating: 3, count: 1_024).write(to: outsideFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -60 * 86_400)],
            ofItemAtPath: outsideFile.path
        )

        let report = await CleanupEngine().analyze(mode: .low, home: home, runningBundleIDs: [])
        XCTAssertTrue(report.candidates.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideFile.path))
    }

    func testHighSkipsCacheOwnedByRunningApp() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = home.appendingPathComponent(
            "Library/Developer/Xcode/DerivedData/Example",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 2_048).write(to: target.appendingPathComponent("index"))

        let report = await CleanupEngine().analyze(
            mode: .high,
            home: home,
            runningBundleIDs: ["com.apple.dt.Xcode"]
        )
        XCTAssertFalse(report.candidates.contains { $0.id == "xcode-derived" })
        XCTAssertTrue(report.warnings.contains { $0.contains("close the owning app") })
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaxOnWaxOffTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
