import SwiftUI

@main
struct WaxOnWaxOffApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 680)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Start Over...") {
                    model.confirmStartOver()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canStartOver)
            }
        }
    }
}
