import AppKit

/// Implement this protocol to add a button to the Touch Bar Control Strip.
/// Then register it in AppDelegate: ButtonRegistry.shared.register(MyAction())
///
/// Minimum required: id, title, activate()
/// Everything else has a sensible default.
protocol TouchStripAction {
    /// Unique slug — becomes the NSTouchBarItem identifier suffix.
    /// Use snake_case, no spaces. e.g. "screenshot", "mute", "timer"
    var id: String { get }

    /// Text shown on the button. Emoji works great. Keep it short.
    var title: String { get }

    /// Button width in points (default: 44)
    var width: CGFloat { get }

    /// Button tint colour (default: white)
    var tintColor: NSColor { get }

    /// Called on the main thread when the button is tapped.
    func activate()
}

protocol LiveTouchStripAction: AnyObject {
    var buttonUpdater: ((String, NSColor) -> Void)? { get set }
}

// MARK: - Defaults

extension TouchStripAction {
    var width: CGFloat { 44 }
    var tintColor: NSColor { .white }

    var identifier: NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("com.touchstrip.\(id)")
    }
}
