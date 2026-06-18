#if DEBUG
import AppKit

enum ScreenshotCapture {
    @MainActor
    static func scheduleIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["WAX_SNAPSHOT_PATH"], !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            capture(path: path, attemptsRemaining: 8)
        }
    }

    @MainActor
    private static func capture(path: String, attemptsRemaining: Int) {
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }),
              let view = window.contentView else {
            guard attemptsRemaining > 0 else {
                NSApplication.shared.terminate(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                capture(path: path, attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }
        view.layoutSubtreeIfNeeded()
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        NSApplication.shared.terminate(nil)
    }
}
#endif
