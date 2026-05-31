import AppKit

/// Manages all Touch Bar Control Strip buttons.
/// Handles DFR registration so individual actions don't need to know about it.
private typealias DFRSetPresenceFn = @convention(c) (CFString, Bool) -> Void

class ButtonRegistry {
    static let shared = ButtonRegistry()

    private var actions: [TouchStripAction] = []
    private var items: [String: TouchStripButtonItem] = [:]

    private static let dfrHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/Versions/A/DFRFoundation",
        RTLD_LAZY
    )

    // MARK: - Public API

    /// Register an action. Call before installAll().
    func register(_ action: TouchStripAction) {
        actions.append(action)
        tsDebugLog("ButtonRegistry: registered '\(action.id)'\n")
    }

    /// Install all registered actions into the Control Strip.
    func installAll() {
        let addSel    = NSSelectorFromString("addSystemTrayItem:")
        let canAdd    = NSTouchBarItem.responds(to: addSel)

        guard let handle = Self.dfrHandle,
              let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") else {
            tsDebugLog("ButtonRegistry: DFRFoundation unavailable — skipping install\n")
            return
        }
        let setPresence = unsafeBitCast(sym, to: DFRSetPresenceFn.self)

        for action in actions {
            let item = TouchStripButtonItem(action: action)
            items[action.id] = item

            if canAdd { NSTouchBarItem.perform(addSel, with: item) }
            setPresence(action.identifier.rawValue as CFString, true)
            tsDebugLog("ButtonRegistry: installed '\(action.id)' → \(action.identifier.rawValue)\n")
        }
    }

    /// Remove all buttons from the Control Strip (called at app quit).
    func uninstallAll() {
        guard let handle = Self.dfrHandle,
              let sym = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") else { return }
        let setPresence = unsafeBitCast(sym, to: DFRSetPresenceFn.self)
        let removeSel   = NSSelectorFromString("removeSystemTrayItem:")
        let canRemove   = NSTouchBarItem.responds(to: removeSel)

        for (id, item) in items {
            if canRemove { NSTouchBarItem.perform(removeSel, with: item) }
            setPresence(item.action.identifier.rawValue as CFString, false)
            tsDebugLog("ButtonRegistry: uninstalled '\(id)'\n")
        }
        items.removeAll()
    }
}
