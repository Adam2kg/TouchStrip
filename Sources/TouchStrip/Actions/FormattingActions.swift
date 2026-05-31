import AppKit

// ── Formatting buttons ────────────────────────────────────────────────────────
// Each sends the standard keyboard shortcut to whatever app is frontmost.
// Works in any app that supports rich text: Mail, Notes, Word, Pages,
// Google Docs (browser), Notion, etc.

private func sendCmd(_ keyCode: CGKeyCode) {
    // Small delay: let the Touch Bar tap finish before we fire the shortcut,
    // otherwise focus may still be on the button and the event goes nowhere.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags   = .maskCommand
        // Post directly to the frontmost app — more reliable than cghidEventTap
        down.postToPid(pid)
        up.postToPid(pid)
        tsDebugLog("format: sent keyCode \(keyCode) to \(frontApp.bundleIdentifier ?? "?")\n")
    }
}

// MARK: - Bold  (⌘B)

struct BoldAction: TouchStripAction {
    let id    = "bold"
    let title = "B"
    var tintColor: NSColor { .white }

    func activate() {
        sendCmd(0x0B)   // B key
    }
}

// MARK: - Italic  (⌘I)   — "Kursiv" in German apps

struct ItalicAction: TouchStripAction {
    let id    = "italic"
    let title = "I"

    func activate() {
        sendCmd(0x22)   // I key
    }
}

// MARK: - Underline  (⌘U)

struct UnderlineAction: TouchStripAction {
    let id    = "underline"
    let title = "U"

    func activate() {
        sendCmd(0x20)   // U key
    }
}
