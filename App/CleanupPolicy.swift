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
    let badge: CandidateBadge
    let kind: Kind
    let ownerBundleIDs: Set<String>
    let defaultSelected: Bool

    init(
        id: String,
        label: String,
        relativePath: String,
        detail: String,
        badge: CandidateBadge,
        kind: Kind,
        ownerBundleIDs: Set<String>,
        defaultSelected: Bool = true
    ) {
        self.id = id
        self.label = label
        self.relativePath = relativePath
        self.detail = detail
        self.badge = badge
        self.kind = kind
        self.ownerBundleIDs = ownerBundleIDs
        self.defaultSelected = defaultSelected
    }
}

struct AppSupportCacheRule: Sendable {
    let id: String
    let label: String
    let relativePath: String
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
            badge: .safe,
            kind: .agedFiles,
            ownerBundleIDs: []
        ),
        .init(
            id: "user-logs",
            label: "Old user logs",
            relativePath: "Library/Logs",
            detail: "Log files older than the selected mode's age rule.",
            badge: .safe,
            kind: .agedFiles,
            ownerBundleIDs: []
        ),
        .init(
            id: "crash-reports",
            label: "Old crash reports",
            relativePath: "Library/Application Support/CrashReporter",
            detail: "Diagnostic reports older than the selected mode's age rule.",
            badge: .safe,
            kind: .agedFiles,
            ownerBundleIDs: []
        ),
    ]

    static let appCaches: [CleanupTarget] = [
        .init(id: "chrome-disk-cache", label: "Chrome disk cache", relativePath: "Library/Caches/Google/Chrome", detail: "Web cache only; browser profiles, history, and saved data remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.google.Chrome"]),
        .init(id: "spotify-disk-cache", label: "Spotify disk cache", relativePath: "Library/Caches/com.spotify.client", detail: "Recreated media and web cache; account and persistent offline storage remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.spotify.client"]),
        .init(id: "chrome-models", label: "Chrome downloaded models", relativePath: "Library/Application Support/Google/Chrome/OptGuideOnDeviceModel", detail: "Re-downloadable on-device model cache.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.google.Chrome"]),
        .init(id: "chrome-components", label: "Chrome component cache", relativePath: "Library/Application Support/Google/Chrome/component_crx_cache", detail: "Re-downloadable browser components.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.google.Chrome"]),
        .init(id: "google-updater", label: "Google updater downloads", relativePath: "Library/Application Support/Google/GoogleUpdater/crx_cache", detail: "Downloaded updater packages.", badge: .confirm, kind: .entireTree, ownerBundleIDs: []),
        .init(id: "teams-cache", label: "Microsoft Teams cache", relativePath: "Library/Application Support/Microsoft/Teams/Cache", detail: "Recreated when Teams runs again.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.microsoft.teams", "com.microsoft.teams2"]),
        .init(id: "teams-code-cache", label: "Microsoft Teams code cache", relativePath: "Library/Application Support/Microsoft/Teams/Code Cache", detail: "Generated web runtime code cache.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.microsoft.teams", "com.microsoft.teams2"]),
        .init(id: "dropbox-gpu", label: "Dropbox GPU cache", relativePath: "Library/Application Support/Dropbox/GPUCache", detail: "Generated rendering data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.getdropbox.dropbox"]),
    ]

    static let developerCaches: [CleanupTarget] = [
        .init(id: "xcode-derived", label: "Xcode DerivedData", relativePath: "Library/Developer/Xcode/DerivedData", detail: "Build products and indexes; projects remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.apple.dt.Xcode"], defaultSelected: false),
        .init(id: "xcode-products", label: "Xcode Products", relativePath: "Library/Developer/Xcode/Products", detail: "Generated build products.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.apple.dt.Xcode"], defaultSelected: false),
        .init(id: "simulator-caches", label: "Simulator caches", relativePath: "Library/Developer/CoreSimulator/Caches", detail: "Generated Simulator cache data; devices remain installed.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.apple.iphonesimulator"], defaultSelected: false),
        .init(id: "swiftpm-cache", label: "Swift package cache", relativePath: "Library/Caches/org.swift.swiftpm", detail: "Downloaded Swift package artifacts.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "homebrew-cache", label: "Homebrew downloads", relativePath: "Library/Caches/Homebrew", detail: "Downloaded formula and cask archives.", badge: .confirm, kind: .agedFiles, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "npm-cache", label: "npm package cache", relativePath: ".npm/_cacache", detail: "Re-downloadable npm package data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "pip-cache", label: "pip package cache", relativePath: "Library/Caches/pip", detail: "Re-downloadable Python package data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "gradle-cache", label: "Gradle module cache", relativePath: ".gradle/caches/modules-2/files-2.1", detail: "Re-downloadable Gradle dependencies.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "yarn-cache", label: "Yarn package cache", relativePath: "Library/Caches/Yarn", detail: "Re-downloadable Yarn package data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "yarn-xdg-cache", label: "Yarn package cache", relativePath: ".cache/yarn", detail: "Re-downloadable Yarn package data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "pnpm-cache", label: "pnpm package store", relativePath: "Library/pnpm/store", detail: "Content-addressed packages that pnpm can download again.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "pnpm-xdg-cache", label: "pnpm package store", relativePath: ".local/share/pnpm/store", detail: "Content-addressed packages that pnpm can download again.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "cocoapods-cache", label: "CocoaPods cache", relativePath: "Library/Caches/CocoaPods", detail: "Downloaded pods that can be fetched again.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "cargo-download-cache", label: "Cargo download cache", relativePath: ".cargo/registry/cache", detail: "Downloaded crate archives; source and projects remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "go-build-cache", label: "Go build cache", relativePath: "Library/Caches/go-build", detail: "Compiled Go build artifacts.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "go-module-downloads", label: "Go module downloads", relativePath: "go/pkg/mod/cache/download", detail: "Downloaded Go modules; may need network access again.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "gradle-distributions", label: "Gradle wrapper distributions", relativePath: ".gradle/wrapper/dists", detail: "Downloaded Gradle versions; may need network access again.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
    ]

    static let appSupportCaches: [AppSupportCacheRule] = [
        .init(id: "chrome-render", label: "Chrome render caches", relativePath: "Library/Application Support/Google/Chrome", ownerBundleIDs: ["com.google.Chrome"]),
        .init(id: "chromium-render", label: "Chromium render caches", relativePath: "Library/Application Support/Chromium", ownerBundleIDs: ["org.chromium.Chromium"]),
        .init(id: "brave-render", label: "Brave render caches", relativePath: "Library/Application Support/BraveSoftware/Brave-Browser", ownerBundleIDs: ["com.brave.Browser"]),
        .init(id: "edge-render", label: "Edge render caches", relativePath: "Library/Application Support/Microsoft Edge", ownerBundleIDs: ["com.microsoft.edgemac"]),
        .init(id: "arc-render", label: "Arc render caches", relativePath: "Library/Application Support/Arc/User Data", ownerBundleIDs: ["company.thebrowser.Browser"]),
        .init(id: "slack-render", label: "Slack render caches", relativePath: "Library/Application Support/Slack", ownerBundleIDs: ["com.tinyspeck.slackmacgap"]),
        .init(id: "discord-render", label: "Discord render caches", relativePath: "Library/Application Support/discord", ownerBundleIDs: ["com.hnc.Discord"]),
        .init(id: "teams-render", label: "Teams render caches", relativePath: "Library/Application Support/Microsoft/Teams", ownerBundleIDs: ["com.microsoft.teams", "com.microsoft.teams2"]),
        .init(id: "vscode-render", label: "VS Code render caches", relativePath: "Library/Application Support/Code", ownerBundleIDs: ["com.microsoft.VSCode"]),
        .init(id: "cursor-render", label: "Cursor render caches", relativePath: "Library/Application Support/Cursor", ownerBundleIDs: ["com.todesktop.230313mzl4w4u92"]),
    ]
}
