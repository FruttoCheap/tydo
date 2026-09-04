import AppKit

/// Borderless, non-activating floating panel — used for both the capture box
/// and the list. `canBecomeKey` returns true so it takes keyboard focus WITHOUT
/// activating the app (so it won't steal activation from the frontmost or
/// fullscreen app). It dismisses itself when it loses key focus; that wiring
/// lives in WindowManager via NSWindowDelegate.windowDidResignKey.
final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
