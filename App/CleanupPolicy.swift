import Foundation

struct CleanupTarget: Sendable {
    enum Kind: Sendable {
        case agedFiles
        case entireTree
    }

    let id: String
    let label: String
    let relativePath: String
    let detail: String
    let risk: CandidateRisk
    let kind: Kind
    let ownerBundleIDs: Set<String>
}

enum CleanupPolicy {
    static func targets(for mode: CleanupMode) -> [CleanupTarget] {
        var targets = baseline
        if mode == .mid || mode == .high {
            targets += appCaches
        }
        if mode == .high {
            targets += developerCaches
        }
        return targets
    }

    static let baseline: [CleanupTarget] = [
        .init(
            id: "user-caches",
            label: "Old user caches",
            relativePath: "Library/Caches",
            detail: "Cache files older than the selected mode's age rule.",
            risk: .safe,
            kind: .agedFiles,
            ownerBundleIDs: []
        ),
        .init(
            id: "user-logs",
            label: "Old user logs",
            relativePath: "Library/Logs",
            detail: "Log files older than the selected mode's age rule.",
            risk: .safe,
            kind: .agedFiles,
            ownerBundleIDs: []
        ),
        .init(
            id: "crash-reports",
            label: "Old crash reports",
            relativePath: "Library/Application Support/CrashReporter",
            detail: "Diagnostic reports older than the selected mode's age rule.",
            risk: .safe,
            kind: .agedFiles,
            ownerBundleIDs: []
        ),
    ]

    static let appCaches: [CleanupTarget] = [
        .init(id: "chrome-models", label: "Chrome downloaded models", relativePath: "Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", detail: "Re-downloadable on-device model cache.", risk: .confirm, kind: .entireTree, ownerBundleIDs: ["com.google.Chrome"]),
        .init(id: "chrome-components", label: "Chrome component cache", relativePath: "Library/Application Support/Google/Chrome/component_crx_cache", detail: "Re-downloadable browser components.", risk: .confirm, kind: .entireTree, ownerBundleIDs: ["com.google.Chrome"]),
        .init(id: "google-updater", label: "Google updater downloads", relativePath: "Library/Application Support/Google/GoogleUpdater/crx_cache", detail: "Downloaded updater packages.", risk: .confirm, kind: .entireTree, ownerBundleIDs: []),
        .init(id: "teams-cache", label: "Microsoft Teams cache", relativePath: "Library/Application Support/Microsoft/Teams/Cache", detail: "Recreated when Teams runs again.", risk: .confirm, kind: .entireTree, ownerBundleIDs: ["com.microsoft.teams", "com.microsoft.teams2"]),
        .init(id: "teams-code-cache", label: "Microsoft Teams code cache", relativePath: "Library/Application Support/Microsoft/Teams/Code Cache", detail: "Generated web runtime code cache.", risk: .confirm, kind: .entireTree, ownerBundleIDs: ["com.microsoft.teams", "com.microsoft.teams2"]),
        .init(id: "dropbox-gpu", label: "Dropbox GPU cache", relativePath: "Library/Application Support/Dropbox/GPUCache", detail: "Generated rendering data.", risk: .confirm, kind: .entireTree, ownerBundleIDs: ["com.getdropbox.dropbox"]),
    ]

    static let developerCaches: [CleanupTarget] = [
        .init(id: "xcode-derived", label: "Xcode DerivedData", relativePath: "Library/Developer/Xcode/DerivedData", detail: "Build products and indexes; projects remain untouched.", risk: .confirm, kind: .entireTree, ownerBundleIDs: ["com.apple.dt.Xcode"]),
        .init(id: "xcode-products", label: "Xcode Products", relativePath: "Library/Developer/Xcode/Products", detail: "Generated build products.", risk: .confirm, kind: .entireTree, ownerBundleIDs: ["com.apple.dt.Xcode"]),
        .init(id: "simulator-caches", label: "Simulator caches", relativePath: "Library/Developer/CoreSimulator/Caches", detail: "Generated Simulator cache data; devices remain installed.", risk: .confirm, kind: .entireTree, ownerBundleIDs: ["com.apple.iphonesimulator"]),
        .init(id: "swiftpm-cache", label: "Swift package cache", relativePath: "Library/Caches/org.swift.swiftpm", detail: "Downloaded Swift package artifacts.", risk: .confirm, kind: .entireTree, ownerBundleIDs: []),
        .init(id: "homebrew-cache", label: "Homebrew downloads", relativePath: "Library/Caches/Homebrew", detail: "Downloaded formula and cask archives.", risk: .confirm, kind: .agedFiles, ownerBundleIDs: []),
        .init(id: "npm-cache", label: "npm package cache", relativePath: ".npm/_cacache", detail: "Re-downloadable npm package data.", risk: .confirm, kind: .entireTree, ownerBundleIDs: []),
        .init(id: "pip-cache", label: "pip package cache", relativePath: "Library/Caches/pip", detail: "Re-downloadable Python package data.", risk: .confirm, kind: .entireTree, ownerBundleIDs: []),
        .init(id: "gradle-cache", label: "Gradle module cache", relativePath: ".gradle/caches/modules-2/files-2.1", detail: "Re-downloadable Gradle dependencies.", risk: .confirm, kind: .entireTree, ownerBundleIDs: []),
    ]
}

