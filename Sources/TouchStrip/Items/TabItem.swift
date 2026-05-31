import AppKit

class TabItem: NSCustomTouchBarItem {
    private var stack: NSStackView!

    override init(identifier: NSTouchBarItem.Identifier) {
        super.init(identifier: identifier)
        stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        view = stack
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let tabs = fetchTabs()
        DispatchQueue.main.async {
            self.stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (i, title) in tabs.prefix(7).enumerated() {
                let short = String(title.prefix(12))
                let btn = NSButton(title: short, target: self, action: #selector(self.switchTab(_:)))
                btn.tag = i + 1
                btn.bezelStyle = .rounded
                btn.font = .systemFont(ofSize: 10)
                self.stack.addArrangedSubview(btn)
            }
        }
    }

    @objc private func switchTab(_ sender: NSButton) {
        let idx = sender.tag
        let script: String
        switch activeBrowser() {
        case "Safari":
            script = "tell application \"Safari\" to set current tab of front window to tab \(idx) of front window"
        case "Google Chrome":
            script = "tell application \"Google Chrome\" to set active tab index of front window to \(idx)"
        case "Firefox":
            // Firefox doesn't support AppleScript tab switching; fall back to Cmd+[n]
            sendCmdNumber(idx)
            return
        default:
            return
        }
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    private func fetchTabs() -> [String] {
        let script: String
        switch activeBrowser() {
        case "Safari":
            script = "tell application \"Safari\" to get name of tabs of front window"
        case "Google Chrome":
            script = "tell application \"Google Chrome\" to get title of tabs of front window"
        default:
            return []
        }
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error),
              result.numberOfItems > 0 else { return [] }
        return (1...result.numberOfItems).compactMap { result.atIndex($0)?.stringValue }
    }

    private func activeBrowser() -> String {
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return "" }
        if bundle.contains("safari") { return "Safari" }
        if bundle.contains("chrome") { return "Google Chrome" }
        if bundle.contains("firefox") { return "Firefox" }
        return ""
    }

    // Fallback: Cmd+1…9 for tab switching
    private func sendCmdNumber(_ n: Int) {
        guard n >= 1, n <= 9 else { return }
        let keyCodes: [Int: CGKeyCode] = [1:18,2:19,3:20,4:21,5:23,6:22,7:26,8:28,9:25]
        guard let code = keyCodes[n] else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
    }
}
