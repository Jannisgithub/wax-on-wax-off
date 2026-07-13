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
            targets += extendedAppCaches
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

    static let extendedAppCaches: [CleanupTarget] = [
        .init(id: "firefox-disk-cache", label: "Firefox disk cache", relativePath: "Library/Caches/Firefox", detail: "Web cache only; profiles, cookies, history, and saved data remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["org.mozilla.firefox"], defaultSelected: false),
        .init(id: "brave-disk-cache", label: "Brave disk cache", relativePath: "Library/Caches/BraveSoftware/Brave-Browser", detail: "Web cache only; browser profiles and saved data remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.brave.Browser"], defaultSelected: false),
        .init(id: "edge-disk-cache", label: "Edge disk cache", relativePath: "Library/Caches/Microsoft Edge", detail: "Web cache only; browser profiles and saved data remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.microsoft.edgemac"], defaultSelected: false),
        .init(id: "arc-disk-cache", label: "Arc disk cache", relativePath: "Library/Caches/Arc", detail: "Web cache only; spaces, profiles, and saved data remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["company.thebrowser.Browser"], defaultSelected: false),
        .init(id: "slack-disk-cache", label: "Slack disk cache", relativePath: "Library/Caches/com.tinyspeck.slackmacgap", detail: "Recreated local cache files; workspace data remains untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.tinyspeck.slackmacgap"], defaultSelected: false),
        .init(id: "discord-disk-cache", label: "Discord disk cache", relativePath: "Library/Caches/com.hnc.Discord", detail: "Recreated local cache files; account and persistent data remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.hnc.Discord"], defaultSelected: false),
        .init(id: "zoom-disk-cache", label: "Zoom disk cache", relativePath: "Library/Caches/us.zoom.xos", detail: "Recreated local cache files; recordings and meeting documents remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["us.zoom.xos"], defaultSelected: false),
    ]

    static let developerCaches: [CleanupTarget] = [
        .init(id: "xcode-derived", label: "Xcode DerivedData", relativePath: "Library/Developer/Xcode/DerivedData", detail: "Build products and indexes; projects remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.apple.dt.Xcode"], defaultSelected: false),
        .init(id: "xcode-products", label: "Xcode Products", relativePath: "Library/Developer/Xcode/Products", detail: "Generated build products.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.apple.dt.Xcode"], defaultSelected: false),
        .init(id: "xcode-documentation-cache", label: "Xcode documentation cache", relativePath: "Library/Developer/Xcode/DocumentationCache", detail: "Downloaded documentation cache that Xcode can fetch again.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.apple.dt.Xcode"], defaultSelected: false),
        .init(id: "xcode-ios-device-support", label: "Xcode iOS device support", relativePath: "Library/Developer/Xcode/iOS DeviceSupport", detail: "Downloaded device symbols and support files; review before removal because debugging older devices may need them again.", badge: .review, kind: .entireTree, ownerBundleIDs: ["com.apple.dt.Xcode"], defaultSelected: false),
        .init(id: "xcode-watchos-device-support", label: "Xcode watchOS device support", relativePath: "Library/Developer/Xcode/watchOS DeviceSupport", detail: "Downloaded device symbols and support files; review before removal because debugging older devices may need them again.", badge: .review, kind: .entireTree, ownerBundleIDs: ["com.apple.dt.Xcode"], defaultSelected: false),
        .init(id: "xcode-tvos-device-support", label: "Xcode tvOS device support", relativePath: "Library/Developer/Xcode/tvOS DeviceSupport", detail: "Downloaded device symbols and support files; review before removal because debugging older devices may need them again.", badge: .review, kind: .entireTree, ownerBundleIDs: ["com.apple.dt.Xcode"], defaultSelected: false),
        .init(id: "xcode-visionos-device-support", label: "Xcode visionOS device support", relativePath: "Library/Developer/Xcode/visionOS DeviceSupport", detail: "Downloaded device symbols and support files; review before removal because debugging older devices may need them again.", badge: .review, kind: .entireTree, ownerBundleIDs: ["com.apple.dt.Xcode"], defaultSelected: false),
        .init(id: "xcode-caches", label: "Xcode caches", relativePath: "Library/Caches/com.apple.dt.Xcode", detail: "Re-downloadable Xcode cache data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.apple.dt.Xcode"], defaultSelected: false),
        .init(id: "simulator-caches", label: "Simulator caches", relativePath: "Library/Developer/CoreSimulator/Caches", detail: "Generated Simulator cache data; devices remain installed.", badge: .confirm, kind: .entireTree, ownerBundleIDs: ["com.apple.iphonesimulator"], defaultSelected: false),
        .init(id: "swiftpm-cache", label: "Swift package cache", relativePath: "Library/Caches/org.swift.swiftpm", detail: "Downloaded Swift package artifacts.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "carthage-cache", label: "Carthage cache", relativePath: "Library/Caches/org.carthage.CarthageKit", detail: "Downloaded and generated Carthage dependency data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "homebrew-cache", label: "Homebrew downloads", relativePath: "Library/Caches/Homebrew", detail: "Downloaded formula and cask archives.", badge: .confirm, kind: .agedFiles, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "homebrew-logs", label: "Homebrew logs", relativePath: "Library/Logs/Homebrew", detail: "Homebrew build and install logs.", badge: .safe, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "npm-cache", label: "npm package cache", relativePath: ".npm/_cacache", detail: "Re-downloadable npm package data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "pip-cache", label: "pip package cache", relativePath: "Library/Caches/pip", detail: "Re-downloadable Python package data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "pip-xdg-cache", label: "pip XDG cache", relativePath: ".cache/pip", detail: "Re-downloadable pip download cache.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "uv-cache", label: "uv package cache", relativePath: "Library/Caches/uv", detail: "Re-downloadable Python package and build data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "uv-xdg-cache", label: "uv package cache", relativePath: ".cache/uv", detail: "Re-downloadable Python package and build data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "poetry-cache", label: "Poetry cache", relativePath: "Library/Caches/pypoetry", detail: "Re-downloadable Poetry package cache.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "gradle-cache", label: "Gradle module cache", relativePath: ".gradle/caches/modules-2/files-2.1", detail: "Re-downloadable Gradle dependencies.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "bazel-cache", label: "Bazel cache", relativePath: ".cache/bazel", detail: "Generated Bazel action cache and external repository data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "yarn-cache", label: "Yarn package cache", relativePath: "Library/Caches/Yarn", detail: "Re-downloadable Yarn package data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "yarn-xdg-cache", label: "Yarn package cache", relativePath: ".cache/yarn", detail: "Re-downloadable Yarn package data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "pnpm-cache", label: "pnpm package store", relativePath: "Library/pnpm/store", detail: "Shared content-addressed package store; review because active projects may depend on it until packages are restored.", badge: .review, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "pnpm-xdg-cache", label: "pnpm package store", relativePath: ".local/share/pnpm/store", detail: "Shared content-addressed package store; review because active projects may depend on it until packages are restored.", badge: .review, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "cocoapods-cache", label: "CocoaPods cache", relativePath: "Library/Caches/CocoaPods", detail: "Downloaded pods that can be fetched again.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "cargo-download-cache", label: "Cargo download cache", relativePath: ".cargo/registry/cache", detail: "Downloaded crate archives; source and projects remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "cargo-registry-src", label: "Cargo registry sources", relativePath: ".cargo/registry/src", detail: "Unpacked remote crate sources; projects remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "cargo-git-checkouts", label: "Cargo git checkouts", relativePath: ".cargo/git/checkouts", detail: "Downloaded git dependency checkouts; projects remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "cargo-git-db", label: "Cargo git database", relativePath: ".cargo/git/db", detail: "Downloaded git dependency repositories; projects remain untouched.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "go-build-cache", label: "Go build cache", relativePath: "Library/Caches/go-build", detail: "Compiled Go build artifacts.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "go-module-downloads", label: "Go module downloads", relativePath: "go/pkg/mod/cache/download", detail: "Downloaded Go modules; may need network access again.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "gradle-distributions", label: "Gradle wrapper distributions", relativePath: ".gradle/wrapper/dists", detail: "Downloaded Gradle versions; may need network access again.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "composer-cache", label: "Composer cache", relativePath: "Library/Caches/composer", detail: "Downloaded PHP package data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "composer-legacy-cache", label: "Composer cache", relativePath: ".composer/cache", detail: "Downloaded PHP package data.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "nuget-packages", label: "NuGet package cache", relativePath: ".nuget/packages", detail: "Downloaded .NET packages that can be restored again.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "bundler-cache", label: "Bundler cache", relativePath: "Library/Caches/Bundler", detail: "Re-downloadable Ruby gem cache.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "pub-cache", label: "Dart pub cache", relativePath: ".pub-cache", detail: "Shared Dart and Flutter packages; review because active projects may require a restore after removal.", badge: .review, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "terraform-plugins", label: "Terraform plugins", relativePath: ".terraform.d/plugin-cache", detail: "Re-downloadable Terraform provider plugins.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "kubernetes-cache", label: "Kubernetes cache", relativePath: ".kube/cache", detail: "Re-downloadable Kubernetes API cache.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "helm-cache", label: "Helm cache", relativePath: "Library/Caches/helm", detail: "Re-downloadable Helm chart cache.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "helm-xdg-cache", label: "Helm XDG cache", relativePath: ".cache/helm", detail: "Re-downloadable Helm chart cache.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "aws-cli-cache", label: "AWS CLI cache", relativePath: ".aws/cli/cache", detail: "Re-downloadable AWS service model cache.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
        .init(id: "gcloud-logs", label: "Google Cloud SDK logs", relativePath: ".config/gcloud/logs", detail: "Google Cloud CLI log files.", badge: .confirm, kind: .entireTree, ownerBundleIDs: [], defaultSelected: false),
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
