import KeyboardShortcuts

/// Global hotkey identities. Defaults are provided so the app is usable on a
/// fresh install; the Settings tab lets the user rebind them and the new
/// binding persists (KeyboardShortcuts stores it in UserDefaults).
extension KeyboardShortcuts.Name {
    static let captureTodo = Self("captureTodo", default: .init(.space, modifiers: [.option]))
    static let showList    = Self("showList",    default: .init(.l, modifiers: [.option]))
    static let showOptions = Self("showOptions", default: .init(.o, modifiers: [.option]))
}
