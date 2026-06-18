#if DEBUG
import AppKit

enum ScreenshotCapture {
    @MainActor
    static func scheduleIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["WAX_SNAPSHOT_PATH"], !path.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }),
                  let view = window.contentView else { return }
            view.layoutSubtreeIfNeeded()
            guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
            NSApplication.shared.terminate(nil)
        }
    }
}
#endif

