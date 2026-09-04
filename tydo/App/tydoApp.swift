import SwiftUI

@main
struct TydoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Tydo", systemImage: "checklist") {
            Button("Open List")    { appDelegate.windowManager.showList() }
            Button("Open Options") { appDelegate.windowManager.showOptions() }
            Divider()
            Button("Quit Tydo")    { NSApplication.shared.terminate(nil) }
        }
    }
}
