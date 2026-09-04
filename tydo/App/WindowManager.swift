import AppKit
import SwiftUI

/// Owns the capture panel, the list panel, and the options window.
/// The capture and list panels are borderless floating modals: they take key
/// focus without activating the app and dismiss themselves on Escape (handled
/// in their SwiftUI views) or when they lose key focus — i.e. the user clicks
/// outside or switches apps (windowDidResignKey, below).
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private let client: TydoCLIClient
    private let processTodos: () -> Void
    private var capturePanel: FloatingPanel?
    private var listPanel: FloatingPanel?
    private var optionsWindow: NSWindow?
    private var clarificationPanel: FloatingPanel?
    private var clarificationTimeout: Task<Void, Never>?
    /// How long a clarification popup lingers before retreating to Settings.
    private let clarificationTimeoutSeconds: UInt64 = 60

    init(client: TydoCLIClient, processTodos: @escaping () -> Void) {
        self.client = client
        self.processTodos = processTodos
        super.init()
    }

    // MARK: - Capture panel

    func toggleCapture() {
        if capturePanel != nil { dismiss(capturePanel); return }
        showCapture()
    }

    func importDocuments(_ documents: [URL]) {
        dismiss(capturePanel)
        showCapture(documents)
    }

    private func showCapture(_ documents: [URL] = []) {
        let panel = makePanel(size: NSSize(width: 580, height: 80)) { [weak self] in
            CaptureView(
                initialDocuments: documents,
                client: self?.client ?? .shared,
                onSaved: { [weak self] in self?.processTodos() },
                onClose: { self?.dismiss(self?.capturePanel) }
            )
        }
        capturePanel = panel
        show(panel)
    }

    // MARK: - List panel

    func showList() {
        if listPanel != nil { dismiss(listPanel); return }
        let panel = makePanel(size: NSSize(width: 720, height: 520)) { [weak self] in
            ListView(client: self?.client ?? .shared, onClose: { self?.dismiss(self?.listPanel) })
        }
        listPanel = panel
        show(panel)
    }

    // MARK: - Clarification popup

    /// Show the oldest not-yet-shown grouping question as a top-centre popup.
    /// Called after each processing sweep. One at a time: if a popup is already
    /// up we wait — the next is shown when this one closes. Timed-out/answered
    /// questions are marked `wasPresented`, so they never re-popup (they live in
    /// Settings from then on); only fresh ones surface here.
    func presentPendingClarifications() {
        guard clarificationPanel == nil else { return }
        let pending = client.snapshot.clarifications
            .filter { !$0.wasPresented }
            .sorted { $0.createdAt < $1.createdAt }
        guard let question = pending.first else { return }

        Task { [weak self] in
            guard let self else { return }
            do { try await client.markPresented(question.id) }
            catch {
                Self.log(error)
                return
            }
            guard clarificationPanel == nil else { return }
            let panel = makePanel(size: NSSize(width: 460, height: 140)) { [weak self] in
                ClarificationPopup(
                    client: self?.client ?? .shared,
                    question: question,
                    onClose: { self?.dismissClarification() }
                )
            }
            panel.delegate = nil
            clarificationPanel = panel
            positionTopCenter(panel)
            panel.makeKeyAndOrderFront(nil)

            clarificationTimeout?.cancel()
            clarificationTimeout = Task { [weak self, clarificationTimeoutSeconds] in
                try? await Task.sleep(nanoseconds: clarificationTimeoutSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.dismissClarification()
            }
        }
    }

    private func dismissClarification() {
        clarificationTimeout?.cancel()
        clarificationTimeout = nil
        clarificationPanel?.orderOut(nil)
        clarificationPanel = nil
        // Chain to the next queued question, if any.
        presentPendingClarifications()
    }

    // MARK: - Options window (standard, activating)

    func showOptions() {
        let window = optionsWindow ?? {
            let w = NSWindow(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 720, height: 520)),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            w.title = "Tydo - Options"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: OptionsView(client: client))
            optionsWindow = w
            return w
        }()
        Task {
            try? await client.refresh()
            try? await client.loadConfig()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Helpers

    private func makePanel<Content: View>(size: NSSize,
                                          @ViewBuilder content: () -> Content) -> FloatingPanel {
        let panel = FloatingPanel(size: size)
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: content())
        // Assigning contentViewController resizes the panel to the hosting
        // controller's fitting size, computed before SwiftUI's first layout
        // pass — often near-zero. Reassert the real size so positioning below
        // isn't centering a phantom zero-size window.
        panel.setContentSize(size)
        return panel
    }

    private func show(_ panel: FloatingPanel) {
        positionOnMouseScreen(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Orders a panel out and clears whichever reference points at it.
    private func dismiss(_ window: NSWindow?) {
        guard let window else { return }
        window.orderOut(nil)
        if window === capturePanel { capturePanel = nil }
        if window === listPanel { listPanel = nil }
    }

    // The panels dismiss when they lose key focus (click outside / app switch).
    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window,
                  !window.isKeyWindow,
                  window.attachedSheet == nil,
                  !(NSApp.keyWindow is NSOpenPanel),
                  !(NSApp.modalWindow is NSOpenPanel) else { return }
            dismiss(window)
        }
    }

    /// Centre a window on whichever screen currently holds the mouse cursor.
    private func positionOnMouseScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        let size = window.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    /// Centre a window horizontally near the top of the mouse's screen.
    private func positionTopCenter(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = window.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 24
        )
        window.setFrameOrigin(origin)
    }

    private static func log(_ error: Error) {
        FileHandle.standardError.write(Data("Tydo CLI: \(error.localizedDescription)\n".utf8))
    }
}
