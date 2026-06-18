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
        .defaultSize(width: 780, height: 590)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Reset Folder Access") {
                    model.resetFolderAccess()
                }
            }
        }
    }
}

