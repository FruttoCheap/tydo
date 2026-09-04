import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let client = TydoCLIClient.shared
    private var maintenanceTask: Task<Void, Never>?
    lazy var windowManager = WindowManager(
        client: client,
        processTodos: { [weak self] in self?.processTodos() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon — menu-bar accessory only. Belt-and-suspenders with
        // LSUIElement in Info.plist.
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        processTodos()

        maintenanceTask = Task { [client] in
            while !Task.isCancelled {
                do { try await client.runMaintenance() }
                catch { Self.log(error) }
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }

        KeyboardShortcuts.onKeyUp(for: .captureTodo) { [weak self] in
            self?.windowManager.toggleCapture()
        }
        KeyboardShortcuts.onKeyUp(for: .showList) { [weak self] in
            self?.windowManager.showList()
        }
        KeyboardShortcuts.onKeyUp(for: .showOptions) { [weak self] in
            self?.windowManager.showOptions()
        }
    }

    @objc func importDocuments(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []).map { $0 as URL }
        guard !urls.isEmpty else {
            error.pointee = "Tydo received no readable files."
            return
        }
        windowManager.importDocuments(urls)
    }

    private func processTodos() {
        Task { [client, windowManager] in
            do { try await client.process() }
            catch { Self.log(error) }
            windowManager.presentPendingClarifications()
        }
    }

    private static func log(_ error: Error) {
        FileHandle.standardError.write(Data("Tydo CLI: \(error.localizedDescription)\n".utf8))
    }
}
